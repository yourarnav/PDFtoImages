cask "pdftoimages" do
  version "1.0.0"
  sha256 "23c6b8ad38daa0834dac24207a6e71bb0ca64f6a105b93f8eeca6bbf7c74e083"

  url "https://github.com/yourarnav/PDFtoImages/releases/download/v#{version}/PDFtoImages.dmg"
  name "PDF to Images"
  desc "Ultra-lightweight native Mac app to convert PDFs into numbered PNG folders"
  homepage "https://pdftoimages.vercel.app"

  depends_on macos: ">= :monterey"
  depends_on formula: "poppler"

  app "PDF to Images.app"

  caveats <<~EOS
    PDF to Images is free and self-signed, so macOS may flag it on first launch.
    Clear the quarantine flag once, then open it normally:
      xattr -dr com.apple.quarantine "/Applications/PDF to Images.app"

    The source code is 100% open at https://github.com/yourarnav/PDFtoImages.
  EOS
end
