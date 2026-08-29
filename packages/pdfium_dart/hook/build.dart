import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:http/http.dart' as http;

const _pdfiumRelease = 'chromium%2F7811';
const _assetName = 'libpdfium';

/// HelloHQ's attested mirror of bblanchon/pdfium-binaries.
///
/// Upstream is fetched over plain HTTPS with no checksum and no provenance, so
/// on Linux, Windows and Android the app linked whatever that URL served at
/// build time — the only native library in the tree outside the trust gate
/// every other one goes through. (Darwin was already fixed separately: the
/// pdfium_flutter local binaryTarget in 94bc8c1.)
///
/// The mirror re-releases the same bytes with SLSA build provenance, and the
/// digests below are checked before anything decodes the archive. Upstream
/// publishes no checksums file, so the mirror's own first adoption is
/// trust-on-first-use; from that point the bytes are immutable and any
/// substitution fails here.
const _mirrorRelease =
    'https://github.com/HelloHQ/pdfium-xcframework/releases/download/'
    'binaries-chromium-7811';

/// SHA-256 per mirrored asset, from the release's SHA256SUMS.
///
/// A target absent from this map is a hard failure, not a fall-through to
/// upstream: silently reverting to an unverified download is exactly the state
/// this change exists to remove.
const _pinnedDigests = <String, String>{
  'pdfium-android-arm.tgz':
      'bb9250eefb33343f56f27f7e60c81ab3236d932c40e21557bf02ca4c276eb832',
  'pdfium-android-arm64.tgz':
      'f51539cadeb5135534305b8bdf8685ce2fbe9991dbbc5b35f553108411b9ed14',
  'pdfium-android-x64.tgz':
      '23faaf6f993a39524d9dc7fafbb760e295f8bd5e9ffa46139bad2299fb5c80f3',
  'pdfium-linux-x64.tgz':
      'e76e0a37aefb843d56f04657475ce612157021b1ebc53d801f2fbfcc537ccf64',
  // macOS is here because the hook returns early for iOS ONLY. Darwin's
  // xcframework covers pdfium_flutter, not pdfium_dart, so a macOS build still
  // asks this hook for a tarball — the first version of this change omitted
  // these two and the hook's own hard-failure caught it:
  //   Exception: No pinned SHA-256 for pdfium-mac-arm64.tgz
  'pdfium-mac-arm64.tgz':
      'f9bbf1ebdc459e5f5ff25b2d457cc21db55ebfc0cf3d89fc1b90ce5445dac394',
  'pdfium-mac-x64.tgz':
      'b31565aacda1f84393cd98438b06b49f21124888785e7dd1ddf015fa4406bd80',
  'pdfium-win-x64.tgz':
      '2e7af12674ac3716cb0e20369bb9fb269ceadfa2f0b0597097a520e6834175a0',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS == OS.iOS) return;

    final target = _PdfiumTarget.fromCodeConfig(input.config.code);
    final outputSubdir = _pdfiumRelease.replaceAll('%2F', '_');
    final outputFile = input.outputDirectoryShared.resolve(
      '$outputSubdir/${target.archivePlatform}-${target.archiveArch}/${target.libraryFileName}',
    );

    await _downloadPdfium(
      outputFile: outputFile,
      target: target,
      pdfiumRelease: _pdfiumRelease,
    );

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: outputFile,
      ),
    );
  });
}

Future<void> _downloadPdfium({
  required Uri outputFile,
  required _PdfiumTarget target,
  required String pdfiumRelease,
}) async {
  final output = File.fromUri(outputFile);
  if (await output.exists()) return;

  final assetName =
      'pdfium-${target.archivePlatform}-${target.archiveArch}.tgz';
  final expected = _pinnedDigests[assetName];
  if (expected == null) {
    throw Exception(
      'No pinned SHA-256 for $assetName. Mirror it into '
      'HelloHQ/pdfium-xcframework and add its digest to _pinnedDigests — do '
      'not fall back to an unverified upstream download.',
    );
  }

  final archiveUri = Uri.parse('$_mirrorRelease/$assetName');

  final response = await http.Client().get(archiveUri);
  if (response.statusCode != 200) {
    throw Exception('Failed to download PDFium: $archiveUri');
  }

  // Verified BEFORE the archive is decoded: a tampered tarball should never
  // reach the decoder, let alone the output file.
  final actual = sha256.convert(response.bodyBytes).toString();
  if (actual != expected) {
    throw Exception(
      'PDFium SHA-256 mismatch for $assetName.\n'
      '  expected: $expected\n'
      '  actual:   $actual\n'
      'The mirrored bytes changed. Do not update the pin without establishing '
      'why.',
    );
  }

  final archive = TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(response.bodyBytes),
  );
  final member = archive.findFile(target.archiveLibraryPath);
  if (member == null) {
    throw Exception(
      'PDFium archive $archiveUri does not contain ${target.archiveLibraryPath}.',
    );
  }

  await output.parent.create(recursive: true);
  await output.writeAsBytes(member.content as List<int>);
}

final class _PdfiumTarget {
  const _PdfiumTarget({
    required this.archivePlatform,
    required this.archiveArch,
    required this.archiveLibraryPath,
    required this.libraryFileName,
  });

  final String archivePlatform;
  final String archiveArch;
  final String archiveLibraryPath;
  final String libraryFileName;

  static _PdfiumTarget fromCodeConfig(CodeConfig config) {
    final arch = switch (config.targetArchitecture) {
      Architecture.ia32 => 'x86',
      Architecture.x64 => 'x64',
      Architecture.arm => 'arm',
      Architecture.arm64 => 'arm64',
      _ => throw UnsupportedError(
        'Unsupported PDFium architecture: ${config.targetArchitecture}',
      ),
    };

    return switch (config.targetOS) {
      OS.android => _PdfiumTarget(
        archivePlatform: 'android',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.so',
        libraryFileName: 'libpdfium.so',
      ),
      OS.windows => _PdfiumTarget(
        archivePlatform: 'win',
        archiveArch: arch,
        archiveLibraryPath: 'bin/pdfium.dll',
        libraryFileName: 'pdfium.dll',
      ),
      OS.linux => _PdfiumTarget(
        archivePlatform: 'linux',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.so',
        libraryFileName: 'libpdfium.so',
      ),
      OS.macOS => _PdfiumTarget(
        archivePlatform: 'mac',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.dylib',
        libraryFileName: 'libpdfium.dylib',
      ),
      _ => throw UnsupportedError(
        'Unsupported PDFium platform: ${config.targetOS}',
      ),
    };
  }
}
