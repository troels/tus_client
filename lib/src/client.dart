import 'dart:async';
import 'dart:convert' show base64, utf8;
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;

import 'exceptions.dart';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:http/http.dart' as http;

/// This class is used for creating or resuming uploads.
class TusClient {
  /// Version of the tus protocol used by the client. The remote server needs to
  /// support this version, too.
  static const tusVersion = "1.0.0";

  /// The tus server Uri
  final Uri url = Uri.parse(
      "https://zzqlztbqjgtnxqlvviqf.functions.supabase.co/create-upload-link");

  final int totalLength;
  Future<Uint8List?> Function() getNextPiece;
  final Map<String, String>? metadata;

  /// Any additional headers
  final Map<String, String>? headers;

  /// The maximum payload size in bytes when uploading the file in chunks (512KB)
  final int chunkSize;

  String? _uploadMetadata;

  Uri? _uploadUrl;

  Future? _chunkPatchFuture;

  TusClient(
    this.getNextPiece,
    this.totalLength, {
    this.headers,
    this.metadata = const {},
    this.chunkSize = 5 * 1024 * 1024,
  }) {
    _uploadMetadata = generateMetadata();
  }

  /// The URI on the server for the file
  Uri? get uploadUrl => _uploadUrl;

  /// The 'Upload-Metadata' header sent to server
  String get uploadMetadata => _uploadMetadata ?? "";

  /// Override this method to use a custom Client
  http.Client getHttpClient() => http.Client();

  String? _uid;

  /// Create a new [upload] throwing [ProtocolException] on server error
  create() async {
    final client = getHttpClient();
    final createHeaders = Map<String, String>.from(headers ?? {})
      ..addAll({
        "Tus-Resumable": tusVersion,
        "Upload-Length": totalLength.toString(),
        // "Upload-Metadata": _uploadMetadata ?? "",
      });

    final response = await client.post(url, headers: createHeaders);
    if (!(response.statusCode >= 200 && response.statusCode < 300) &&
        response.statusCode != 404) {
      throw ProtocolException(
          "unexpected status code (${response.statusCode}) while creating upload");
    }

    _uid = response.headers["stream-media-id"];

    String urlStr = response.headers["location"] ?? "";
    if (urlStr.isEmpty) {
      throw ProtocolException(
          "missing upload Uri in response for creating upload");
    }

    _uploadUrl = _parseUrl(urlStr);
  }

  /// Start or resume an upload in chunks of [maxChunkSize] throwing
  /// [ProtocolException] on server error
  upload({
    Function(double)? onProgress,
    dynamic Function(String? uid)? onComplete,
  }) async {
    await create();

    // get offset from server
    int offset = await _getOffset();

    // start upload
    final client = getHttpClient();

    while (!_finishedUpload()) {
      final uploadHeaders = {
        "Tus-Resumable": tusVersion,
        "Upload-Offset": "$offset",
        "Content-Type": "application/offset+octet-stream"
      };
      final body = await _getData();
      if (body == null) {
        break;
      }

      _chunkPatchFuture =
          client.patch(_uploadUrl as Uri, headers: uploadHeaders, body: body);
      final response = await _chunkPatchFuture;
      _chunkPatchFuture = null;

      offset += body.length;

      // check if correctly uploaded
      if (!(response.statusCode >= 200 && response.statusCode < 300)) {
        throw ProtocolException(
            "unexpected status code (${response.statusCode}) while uploading chunk");
      }

      int? serverOffset = _parseOffset(response.headers["upload-offset"]);
      if (serverOffset == null) {
        throw ProtocolException(
            "response to PATCH request contains no or invalid Upload-Offset header");
      }
      if (offset != serverOffset) {
        throw ProtocolException(
            "response contains different Upload-Offset value ($serverOffset) than expected ($offset)");
      }

      // update progress
      if (onProgress != null) {
        onProgress(offset / totalLength);
      }
    }
    if (onComplete != null) {
      onComplete(_uid);
    }
  }

  /// Override this to customize creating 'Upload-Metadata'
  String generateMetadata() {
    final meta = Map<String, String>.from(metadata ?? {});

    return meta.entries
        .map((entry) =>
            "${entry.key} ${base64.encode(utf8.encode(entry.value))}")
        .join(",");
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
    final client = getHttpClient();

    final offsetHeaders = {
      "Tus-Resumable": tusVersion,
    };
    final response =
        await client.head(_uploadUrl as Uri, headers: offsetHeaders);

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      throw ProtocolException(
          "unexpected status code (${response.statusCode}) while resuming upload");
    }

    int? serverOffset = _parseOffset(response.headers["upload-offset"]);
    if (serverOffset == null) {
      throw ProtocolException(
          "missing upload offset in response for resuming upload");
    }
    return serverOffset;
  }

  Uint8List? lastFile;
  int? lastFileOffset;
  bool endOfStream = false;

  bool _finishedUpload() => endOfStream;

  /// Get data from file to upload
  Future<Uint8List?> _getData() async {
    BytesBuilder bytes = BytesBuilder();

    print("Getting data");
    if (endOfStream) {
      return null;
    }
    Uint8List? curFile = lastFile;
    int? curFileOffset = lastFileOffset;

    if (curFile == null) {
      curFile = await getNextPiece();
      curFileOffset = 0;

      if (curFile == null) {
        endOfStream = true;
        return null;
      }
    }

    while (true) {
      print("Bytes length: ${bytes.length}");
      if (curFile != null && curFileOffset != null) {
        int lastByte =
            min(curFileOffset + chunkSize - bytes.length, curFile.length);
        bytes.add(curFile.sublist(curFileOffset, lastByte));
        curFileOffset = lastByte;
      }
      if (bytes.length >= chunkSize) {
        if (curFile != null &&
            curFileOffset != null &&
            curFileOffset < curFile.length) {
          lastFile = curFile;
          lastFileOffset = curFileOffset;
        }
        print("${bytes.length}");
        return bytes.takeBytes();
      }
      curFile = await getNextPiece();
      if (curFile == null) {
        endOfStream = true;
        lastFile = null;
        lastFileOffset = null;
        if (bytes.isNotEmpty) {
          print("Length: ${bytes.length}");

          return bytes.takeBytes();
        }
        return null;
      }
      curFileOffset = 0;
    }
  }

  int? _parseOffset(String? offset) {
    if (offset == null || offset.isEmpty) {
      return null;
    }
    if (offset.contains(",")) {
      offset = offset.substring(0, offset.indexOf(","));
    }
    return int.tryParse(offset);
  }

  Uri _parseUrl(String urlStr) {
    if (urlStr.contains(",")) {
      urlStr = urlStr.substring(0, urlStr.indexOf(","));
    }
    Uri uploadUrl = Uri.parse(urlStr);
    if (uploadUrl.host.isEmpty) {
      uploadUrl = uploadUrl.replace(host: url.host, port: url.port);
    }
    if (uploadUrl.scheme.isEmpty) {
      uploadUrl = uploadUrl.replace(scheme: url.scheme);
    }
    return uploadUrl;
  }
}
