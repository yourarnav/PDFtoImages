cask "pdftoimages" do
  version "1.0.0"
  sha256 "67c09560b9b563b6b7b0d31cac030ffd7abb591b6d4603b2373264842e901dfb"

  url "https://github.com/yourarnav/PDFtoImages/releases/download/v#{version}/PDFtoImages.dmg"
  name "PDF to Images"
  desc "Ultra-lightweight native Mac app to convert PDFs into numbered PNG folders"
  homepage "https://pdftoimages.vercel.app"

  depends_on macos: :monterey
  depends_on formula: "poppler"

  app "PDF to Images.app"

  caveats <<~EOS
    PDF to Images is free and ad-hoc signed, so macOS may flag it on first launch.
    Clear the quarantine flag once, then open it normally:
      xattr -dr com.apple.quarantine "/Applications/PDF to Images.app"

    The source code is 100% open at https://github.com/yourarnav/PDFtoImages.
  EOS
end
