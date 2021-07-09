// Copyright 2021 eaaomk All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

library cache_image;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class CacheImage extends ImageProvider<CacheImage> {
  /// Creates an object that fetches the image at the given URL.
  ///
  /// The arguments [url] and [scale] must not be null.
  const CacheImage(this.url, {this.scale = 1.0, this.headers});

  final String url;

  final double scale;

  final Map<String, String>? headers;

  @override
  Future<CacheImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CacheImage>(this);
  }

  @override
  ImageStreamCompleter load(CacheImage key, DecoderCallback decode) {
    // Ownership of this controller is handed off to [_loadAsync]; it is that
    // method's responsibility to close the controller's stream when the image
    // has been loaded or an error is thrown.
    final StreamController<ImageChunkEvent> chunkEvents = StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () {
        return <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<CacheImage>('Image key', key),
        ];
      },
    );
  }

  // Do not access this field directly; use [_httpClient] instead.
  // We set `autoUncompress` to false to ensure that we can trust the value of
  // the `Content-Length` HTTP header. We automatically uncompress the content
  // in our call to [consolidateHttpClientResponseBytes].
  static final HttpClient _sharedHttpClient = HttpClient()..autoUncompress = false;

  static HttpClient get _httpClient {
    HttpClient client = _sharedHttpClient;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null) client = debugNetworkImageHttpClientProvider!();
      return true;
    }());
    return client;
  }

  Future<ui.Codec> _loadAsync(
      CacheImage key,
      StreamController<ImageChunkEvent> chunkEvents,
      DecoderCallback decode,
      ) async {
    try {
      assert(key == this);

      final Uint8List? bytes = await _get(key.url);
      if (bytes!=null&&bytes.lengthInBytes != 0) {
        return await PaintingBinding.instance!.instantiateImageCodec(bytes);
      }

      final Uri resolved = Uri.base.resolve(key.url);

      final HttpClientRequest request = await _httpClient.getUrl(resolved);

      headers?.forEach((String name, String value) {
        request.headers.add(name, value);
      });
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        // The network may be only temporarily unavailable, or the file will be
        // added on the server later. Avoid having future calls to resolve
        // fail to check the network again.
        await response.drain<List<int>>();
        throw NetworkImageLoadException(statusCode: response.statusCode, uri: resolved);
      }

      final  Uint8List bytes1 = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: (int cumulative, int? total) {
          chunkEvents.add(ImageChunkEvent(
            cumulativeBytesLoaded: cumulative,
            expectedTotalBytes: total,
          ));
        },
      );

      if (bytes1.lengthInBytes != 0) _save(bytes1, key.url);
      if (bytes1.lengthInBytes == 0) throw Exception('CacheImage is an empty file: $resolved');

      return decode(bytes1);
    } catch (e) {
      // Depending on where the exception was thrown, the image cache may not
      // have had a chance to track the key in the cache at all.
      // Schedule a microtask to give the cache a chance to add the key.
      scheduleMicrotask(() {
        PaintingBinding.instance!.imageCache!.evict(key);
      });
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is CacheImage && other.url == url && other.scale == scale;
  }

  @override
  int get hashCode => ui.hashValues(url, scale);

  @override
  String toString() => '${objectRuntimeType(this, 'CacheImage')}("$url", scale: $scale)';

  void _save(Uint8List uint8list, String name) async {
    name = _generateMD5(name);
    Directory dir = await getTemporaryDirectory();
    String path = dir.path + "/" + name;
    //You can customize the path address of the cached image here
    var file = File(path);
    bool exist = await file.exists();
    if (!exist) File(path).writeAsBytesSync(uint8list);
  }

  Future<Uint8List?> _get(String name) async {
    name = _generateMD5(name);
    Directory dir = await getTemporaryDirectory();
    String path = dir.path + "/" + name;
    var file = File(path);
    bool exist = await file.exists();
    if (exist) {
      final Uint8List bytes = await file.readAsBytes();
      return bytes;
    }
  }
}

String _generateMD5(String data) {
  var content = Utf8Encoder().convert(data);
  var digest = md5.convert(content);
  return digest.toString();
}
