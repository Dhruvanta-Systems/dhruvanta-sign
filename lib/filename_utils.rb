# frozen_string_literal: true

module FilenameUtils
  DANGEROUS_EXTENSIONS = %w[
    exe com bat cmd scr pif vbs vbe js jse wsf wsh msi msp
    hta cpl jar app deb rpm dmg pkg mpkg dll so dylib sys
    inf reg ps1 psm1 psd1 ps1xml psc1 pssc vb vba
    sh bash zsh fish run out bin elf gadget workflow lnk scf
    url desktop application action apk ipa xap appx
    appxbundle msix msixbundle diagcab diagpkg msc ocx
    drv ins isp mst paf prf shb shs slk ws wsc inf1 inf2
  ].freeze

  DANGEROUS_EXTENSIONS_REGEXP = /\.(#{Regexp.union(DANGEROUS_EXTENSIONS).source})\W*\z/i

  module_function

  def dangerous_extension(filename)
    ActiveStorage::Filename.wrap(filename).sanitized[DANGEROUS_EXTENSIONS_REGEXP, 1]&.downcase
  end

  # The name used in a download URL. In hosted mode a URL path must stay plain ASCII
  # (a gateway can refuse any percent-escape), so the name becomes a slug and the
  # real name travels in Content-Disposition. Stock mode keeps the name as is.
  def url_filename(filename)
    Extensions.hosted? ? ascii_slug(filename) : filename
  end

  FALLBACK_NAME = 'file'

  # Lowercase [a-z0-9._-]; spaces become "-"; accents are dropped to their base
  # letter and anything with no ASCII form (other scripts, emoji, symbols) is
  # removed. The extension is kept when it survives; when nothing is left the name
  # is "file".
  def ascii_slug(filename)
    name = File.basename(filename.to_s.dup.force_encoding(Encoding::UTF_8).scrub('').gsub(/[[:cntrl:]]/, '').tr('\\', '/'))
    extension = slug_part(File.extname(name)).delete_prefix('.').tr('.', '')
    base = slug_part(File.basename(name, File.extname(name))).gsub(/\A[.-]+|[.-]+\z/, '')
    base = FALLBACK_NAME if base.empty?

    extension.empty? ? base : "#{base}.#{extension}"
  end

  def slug_part(text)
    text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('')

    I18n.transliterate(text.unicode_normalize(:nfkd), replacement: '')
        .downcase.gsub(/\s+/, '-').gsub(/[^a-z0-9._-]/, '').squeeze('-').gsub(/\.{2,}/, '.')
  end

  def basename(filename)
    File.basename(filename, File.extname(filename))
  end
end
