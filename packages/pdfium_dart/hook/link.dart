import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _darwinPdfiumProviderMetadataKey = 'darwin_pdfium_provider';
const _pdfiumFlutterXcframeworkProvider = 'pdfium_flutter_xcframework';
const _pdfiumAssetId = 'package:pdfium_dart/libpdfium';

void main(List<String> args) async {
  await link(args, linkPdfiumAssets);
}

Future<void> linkPdfiumAssets(LinkInput input, LinkOutputBuilder output) async {
  if (!input.config.buildCodeAssets) {
    output.assets.addEncodedAssets(input.assets.encodedAssets);
    return;
  }

  final targetOS = input.config.code.targetOS;
  final pdfiumProvidedByFlutter =
      input.metadata[_darwinPdfiumProviderMetadataKey] ==
      _pdfiumFlutterXcframeworkProvider;
  // When pdfium_flutter's XCFramework is in the app, do not also bundle
  // pdfium_dart's native-assets pdfium.framework. On macOS those two names
  // collide case-insensitively (PDFium vs pdfium); dyld on macOS 27 then
  // rejects the install-name leaf mismatch (hellohq#463). Flutter tests that
  // import only pdfium_dart never set this metadata, so they still get the
  // native asset.
  final shouldOmitDarwinPdfiumAsset =
      pdfiumProvidedByFlutter && (targetOS == OS.iOS || targetOS == OS.macOS);

  for (final asset in input.assets.encodedAssets) {
    final isPdfiumAsset =
        asset.isCodeAsset && CodeAsset.fromEncoded(asset).id == _pdfiumAssetId;
    if (shouldOmitDarwinPdfiumAsset && isPdfiumAsset) continue;

    output.assets.addEncodedAsset(asset);
  }
}
