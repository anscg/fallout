# frozen_string_literal: true

require "tmpdir"

module ShipChecks
  # Renders page 1 of a PDF to PNG bytes. Returns nil on any failure.
  #
  # PDFs never reach libvips. Active Storage calls Vips.block_untrusted(true) for
  # CVE-2026-66066, which disables pdfload, and we do not re-enable it. poppler runs
  # instead as a short-lived child process with an empty environment, resource limits,
  # and an empty working directory. libvips only ever receives the resulting PNG,
  # which a fuzzed loader handles.
  #
  # The empty environment matters: the CVE's disclosure primitive reads
  # /proc/self/environ, and the child has no secrets there. This narrows the blast
  # radius. It is not a sandbox. A poppler remote-code-execution bug still runs as
  # the app user in this container, and can read the parent environment through
  # /proc. Full containment needs a separate one-shot container or seccomp.
  module PdfRasterizer
    RENDER_DPI = 150
    MAX_INPUT_BYTES = 50 * 1024 * 1024
    MAX_OUTPUT_BYTES = 64 * 1024 * 1024
    TIMEOUT_SECONDS = 20
    CPU_SECONDS = 15
    OPEN_FILE_LIMIT = 256
    # Linux only. Darwin reserves a large virtual address space per process, so this
    # cap kills pdftoppm immediately on a developer machine. Production is Linux, so
    # the limit still applies where it matters; elsewhere the container memory limit
    # is the backstop.
    ADDRESS_SPACE_BYTES = 2 * 1024 * 1024 * 1024

    # Absolute path only: the child runs with an empty environment, so it has no
    # PATH to resolve a bare command name against.
    PDFTOPPM_CANDIDATES = [
      "/usr/bin/pdftoppm",
      "/opt/homebrew/bin/pdftoppm",
      "/usr/local/bin/pdftoppm"
    ].freeze

    def self.available?
      pdftoppm_path.present?
    end

    def self.pdftoppm_path
      @pdftoppm_path ||= [ ENV["PDFTOPPM_PATH"], *PDFTOPPM_CANDIDATES ]
        .compact_blank
        .find { |path| File.executable?(path) }
    end

    def self.to_png(pdf_bytes)
      return nil if pdf_bytes.blank?
      return nil if pdf_bytes.bytesize > MAX_INPUT_BYTES
      # Sniff the content rather than trusting a declared type or extension, so we
      # only ever spawn poppler for bytes that really are a PDF.
      return nil unless pdf_bytes.byteslice(0, 5) == "%PDF-"

      unless available?
        Rails.logger.warn("PdfRasterizer: pdftoppm not installed, skipping PDF")
        return nil
      end

      Dir.mktmpdir("pdf_raster") do |dir|
        input = File.join(dir, "in.pdf")
        File.binwrite(input, pdf_bytes)
        prefix = File.join(dir, "out")

        return nil unless render(input, prefix, dir)

        output = "#{prefix}.png"
        return nil unless File.exist?(output)

        size = File.size(output)
        return nil if size.zero? || size > MAX_OUTPUT_BYTES

        File.binread(output)
      end
    rescue StandardError => e
      Rails.logger.warn("PdfRasterizer failed: #{e.class}: #{e.message}")
      nil
    end

    def self.render(input, prefix, dir)
      options = {
        unsetenv_others: true, # no credentials in the child's environment
        chdir: dir,            # working directory holds only the input PDF
        in: File::NULL, out: File::NULL, err: File::NULL,
        rlimit_cpu: CPU_SECONDS,
        rlimit_fsize: MAX_OUTPUT_BYTES,
        rlimit_nofile: OPEN_FILE_LIMIT
      }
      options[:rlimit_as] = ADDRESS_SPACE_BYTES if RUBY_PLATFORM.include?("linux")

      # HOME is the only variable we pass, and it points at the throwaway directory.
      # fontconfig wants a writable home for its cache; without one it can fall back
      # to rebuilding state on every call. Nothing sensitive is exposed by this.
      pid = Process.spawn(
        { "HOME" => dir },
        pdftoppm_path,
        "-png",        # PNG out: libvips loads PNG with a fuzzed loader
        "-singlefile", # one file named "#{prefix}.png", no page-number suffix
        "-f", "1", "-l", "1", # first page only, whatever the page count
        "-r", RENDER_DPI.to_s,
        input, prefix,
        **options
      )
      wait_for(pid)
    end
    private_class_method :render

    # rlimit_cpu stops a spin, but not a process that sleeps or blocks. Enforce
    # wall-clock separately and kill the child if it passes the deadline.
    def self.wait_for(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_SECONDS

      loop do
        finished, status = Process.waitpid2(pid, Process::WNOHANG)
        if finished
          return true if status&.success?

          # Log the reason: a silent nil here is indistinguishable from a PDF we
          # simply chose not to render.
          Rails.logger.warn("PdfRasterizer: pdftoppm exit=#{status&.exitstatus.inspect} signal=#{status&.termsig.inspect}")
          return false
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill("KILL", pid)
          Process.waitpid(pid)
          Rails.logger.warn("PdfRasterizer: pdftoppm passed #{TIMEOUT_SECONDS}s, killed")
          return false
        end

        sleep 0.05
      end
    rescue Errno::ECHILD, Errno::ESRCH
      false
    end
    private_class_method :wait_for
  end
end
