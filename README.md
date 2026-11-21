# Convert Everything

Convert any file on your Mac by renaming it. Change `notes.md` to `notes.pdf`, `photo.heic` to
`photo.jpg` or `song.wav` to `song.mp3`, and the file is converted in place. The app lives in the
menu bar and watches the folders you choose (Desktop, Documents and Downloads by default).

<img src="docs/screenshot.png" alt="The Convert Everything menu: recent conversions grouped by day" width="340">

- **Images:** PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP, AVIF, ICO
- **Documents:** PDF, Markdown (with LaTeX math), TXT, HTML, Word (.docx/.doc), RTF, ODT, Pages,
  PowerPoint (.pptx/.ppt), Keynote
- **Spreadsheets:** Excel (.xlsx/.xls), CSV, Numbers
- **Audio:** MP3, WAV, M4A, AAC, FLAC, Ogg, Opus, AIFF
- **Video:** MP4, MOV, M4V, and video → GIF

Click **Formats** in the menu to see every conversion. Rename a file back to its old extension to undo.
Everything runs on your Mac: no uploads, no accounts.

## Install

Download the latest `Convert Everything.zip` from
[Releases](../../releases), unzip it and drag the app into Applications. It needs macOS 14 (Sonoma)
or later and runs on Apple Silicon and Intel Macs.

Keynote, Pages and Numbers (free from Apple) are optional: they give the best results for
PowerPoint → PDF and Word → PDF, and Numbers is needed for Excel → PDF.

## Build from source

Requirements: Xcode 26 or later, Homebrew on an Apple Silicon Mac, and Rosetta
(`softwareupdate --install-rosetta`) to build the Intel half of the libraries.

```bash
git clone https://github.com/JayBirdZhang/convert-everything.git
cd convert-everything
./Scripts/build-dependencies.sh     # builds LAME and libwebp into ThirdParty/ (about a minute)
open "file converter.xcodeproj"
```

In Xcode, choose your own team under *Signing & Capabilities* (and, if you like, your own bundle
identifier), then build and run. `ThirdParty/` is not checked in; the script makes it from the
official source releases, fetched and checksum-verified by Homebrew.

## How it works

Most conversions use macOS's own frameworks: ImageIO, PDFKit, AVFoundation, WebKit, Vision (text
recognition) and Quick Look. Two small libraries are built into the app: LAME for MP3 and libwebp for
WebP. Word, PowerPoint and spreadsheet files are read and written directly; Keynote, Pages and Numbers
are scripted when they're installed and give a better result.

## License

MIT; see [LICENSE](LICENSE). The bundled libraries keep their own licenses (LAME: LGPL 2;
libwebp: BSD 3-Clause); see [ThirdPartyNotices.txt](file%20converter/ThirdPartyNotices.txt).
The name "Convert Everything" and the app icon are not covered by the MIT License.
