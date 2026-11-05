import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 从源 MP4 解析出的设备与拍摄元数据
class Mp4DeviceInfo {
  final String make;
  final String model;
  final DateTime? creationTime;
  final String? gpsIso6709;

  const Mp4DeviceInfo({
    required this.make,
    required this.model,
    this.creationTime,
    this.gpsIso6709,
  });
}

/// 视频轨时间基与帧时长信息
class _VideoTrackTiming {
  final int trackId;
  final int videoTimescale;
  final int videoDuration;
  final int frameDelta;

  const _VideoTrackTiming({
    required this.trackId,
    required this.videoTimescale,
    required this.videoDuration,
    required this.frameDelta,
  });
}

/// 纯 Dart 跨平台媒体元数据与容器封装引擎（零外部 Perl / exiftool 依赖，彻底兼容中英文路径与无 Homebrew 环境）：
/// 1. 从源 MP4 提取真实设备品牌/型号、拍摄时间与 GPS 信息；
/// 2. 从单帧 HEVC MP4 提取 hvcC 与 hvc1 码流，纯 Dart 封装为原生 Apple 实况 .HEIC 容器并写入 Exif 与完整 Apple MakerNote；
/// 3. 直接构造标准 TIFF/EXIF APP1 段用于 Google Motion Photo (.jpg)；
/// 4. 直接在 .MOV 的 moov 原子中更新 mvhd/tkhd/mdhd 时间戳、注入 com.apple.quicktime.still-image-time (mebx) 定时元数据轨
///    以及 Apple QuickTime mdta (Keys:ContentIdentifier / Make / Model / CreationDate / LivePhotoAuto / VitalityScore)。
class MediaMetadata {
  static const int _qtEpochOffset = 2082844800; // 1904-01-01 至 1970-01-01 秒数

  /// 从源 MP4 文件读取设备信息（Make / Model / 拍摄时间 / GPS）
  static Future<Mp4DeviceInfo> extractFromMp4(String mp4Path) async {
    String? make;
    String? model;
    DateTime? creationTime;
    String? gps;

    try {
      final f = File(mp4Path);
      if (await f.exists()) {
        final raf = await f.open();
        try {
          final fileLen = await raf.length();
          int pos = 0;
          while (pos + 8 <= fileLen) {
            await raf.setPosition(pos);
            final hdr = await raf.read(16);
            if (hdr.length < 8) break;
            final bd = ByteData.sublistView(hdr);
            int sz = bd.getUint32(0);
            final typ = ascii.decode(hdr.sublist(4, 8), allowInvalid: true);
            int hdrLen = 8;
            if (sz == 1 && hdr.length >= 16) {
              sz = bd.getUint64(8);
              hdrLen = 16;
            } else if (sz == 0) {
              sz = fileLen - pos;
            }
            if (sz < hdrLen || pos + sz > fileLen) break;

            if (typ == 'moov' && sz - hdrLen <= 32 * 1024 * 1024) {
              await raf.setPosition(pos + hdrLen);
              final moovBytes = await raf.read(sz - hdrLen);
              final parsed = _parseMoovMetadata(moovBytes);
              make = parsed.make ?? make;
              model = parsed.model ?? model;
              creationTime = parsed.creationTime ?? creationTime;
              gps = parsed.gpsIso6709 ?? gps;
              break;
            }
            pos += sz;
          }

          if (model == null || model.isEmpty) {
            await raf.setPosition(0);
            final headLen = fileLen < 256 * 1024 ? fileLen : 256 * 1024;
            final head = await raf.read(headLen);
            final text = latin1.decode(head, allowInvalid: true);
            final djiMatch = RegExp(
              r'(DJI\s*Osmo\s*Pocket\s*[0-9A-Za-z]+|OsmoPocket[0-9A-Za-z]+|DJI\s*[A-Za-z0-9_-]{3,20})',
            ).firstMatch(text);
            if (djiMatch != null) {
              final raw = djiMatch.group(0)!.trim();
              if (!raw.startsWith('DJI_20') && !raw.contains('TPLG')) {
                model = raw.startsWith('DJI') ? raw : 'DJI $raw';
                make ??= 'DJI';
              }
            }
          }
        } finally {
          await raf.close();
        }
      }
    } catch (_) {}

    final finalMake = (make != null && make.trim().isNotEmpty) ? make.trim() : 'DJI';
    final finalModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : 'DJI OsmoPocket4P';

    return Mp4DeviceInfo(
      make: finalMake,
      model: finalModel,
      creationTime: creationTime,
      gpsIso6709: gps,
    );
  }

  static Mp4DeviceInfo _parseMoovMetadata(Uint8List moov) {
    String? make;
    String? model;
    DateTime? creationTime;
    String? gps;

    void walk(int start, int end) {
      int pos = start;
      while (pos + 8 <= end) {
        final bd = ByteData.sublistView(moov, pos, pos + 8);
        int sz = bd.getUint32(0);
        final typ = latin1.decode(moov.sublist(pos + 4, pos + 8));
        if (sz == 0) sz = end - pos;
        if (sz < 8 || pos + sz > end) break;

        final bodyStart = pos + 8;
        final bodyEnd = pos + sz;

        if (typ == 'mvhd' && bodyEnd - bodyStart >= 12) {
          final ver = moov[bodyStart];
          final mBd = ByteData.sublistView(moov, bodyStart, bodyEnd);
          final qtSec = ver == 1 && bodyEnd - bodyStart >= 20
              ? mBd.getUint64(4)
              : mBd.getUint32(4);
          if (qtSec > _qtEpochOffset) {
            final unixSec = qtSec - _qtEpochOffset;
            creationTime ??= DateTime.fromMillisecondsSinceEpoch(
              unixSec * 1000,
              isUtc: true,
            ).toLocal();
          }
        } else if (typ == 'udta') {
          walk(bodyStart, bodyEnd);
        } else if (typ == 'meta') {
          int sub = bodyStart;
          if (sub + 8 <= bodyEnd) {
            final nextType = latin1.decode(moov.sublist(sub + 4, sub + 8));
            if (nextType != 'hdlr' && sub + 12 <= bodyEnd) {
              sub += 4;
            }
          }
          final kv = _parseQtMetaKeysIlst(moov, sub, bodyEnd);
          make ??= kv['com.apple.quicktime.make'] ?? kv['make'];
          model ??= kv['com.apple.quicktime.model'] ?? kv['model'];
          gps ??= kv['com.apple.quicktime.location.ISO6709'];
          walk(sub, bodyEnd);
        } else if (typ == 'ilst') {
          walk(bodyStart, bodyEnd);
        } else if (typ == '\xa9mak') {
          make ??= _readTextAtom(moov, bodyStart, bodyEnd);
        } else if (typ == '\xa9mod') {
          model ??= _readTextAtom(moov, bodyStart, bodyEnd);
        } else if (typ == '\xa9xyz') {
          gps ??= _readTextAtom(moov, bodyStart, bodyEnd);
        }
        pos += sz;
      }
    }

    walk(0, moov.length);
    return Mp4DeviceInfo(
      make: make ?? '',
      model: model ?? '',
      creationTime: creationTime,
      gpsIso6709: gps,
    );
  }

  static Map<String, String> _parseQtMetaKeysIlst(Uint8List buf, int start, int end) {
    final result = <String, String>{};
    final keyNames = <int, String>{};
    int pos = start;
    while (pos + 8 <= end) {
      final bd = ByteData.sublistView(buf, pos, pos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(buf.sublist(pos + 4, pos + 8));
      if (sz < 8 || pos + sz > end) break;
      if (typ == 'keys' && sz >= 16) {
        final count = ByteData.sublistView(buf, pos + 12, pos + 16).getUint32(0);
        int kPos = pos + 16;
        for (int i = 1; i <= count && kPos + 8 <= pos + sz; i++) {
          final kSz = ByteData.sublistView(buf, kPos, kPos + 4).getUint32(0);
          if (kSz < 8 || kPos + kSz > pos + sz) break;
          keyNames[i] = utf8.decode(
            buf.sublist(kPos + 8, kPos + kSz),
            allowMalformed: true,
          );
          kPos += kSz;
        }
      } else if (typ == 'ilst' && keyNames.isNotEmpty) {
        int iPos = pos + 8;
        while (iPos + 8 <= pos + sz) {
          final iBd = ByteData.sublistView(buf, iPos, iPos + 8);
          final iSz = iBd.getUint32(0);
          final idx = iBd.getUint32(4);
          if (iSz < 8 || iPos + iSz > pos + sz) break;
          final val = _readDataAtom(buf, iPos + 8, iPos + iSz);
          if (val != null && keyNames.containsKey(idx)) {
            result[keyNames[idx]!] = val;
          }
          iPos += iSz;
        }
      }
      pos += sz;
    }
    return result;
  }

  static String? _readDataAtom(Uint8List buf, int start, int end) {
    int pos = start;
    while (pos + 8 <= end) {
      final sz = ByteData.sublistView(buf, pos, pos + 4).getUint32(0);
      final typ = latin1.decode(buf.sublist(pos + 4, pos + 8));
      if (sz < 8 || pos + sz > end) break;
      if (typ == 'data' && sz > 16) {
        return utf8.decode(buf.sublist(pos + 16, pos + sz), allowMalformed: true).trim();
      }
      pos += sz;
    }
    return null;
  }

  static String? _readTextAtom(Uint8List buf, int start, int end) {
    final dataVal = _readDataAtom(buf, start, end);
    if (dataVal != null && dataVal.isNotEmpty) return dataVal;
    if (end - start > 4) {
      final strLen = ByteData.sublistView(buf, start, start + 2).getUint16(0);
      if (start + 4 + strLen <= end) {
        return utf8
            .decode(buf.sublist(start + 4, start + 4 + strLen), allowMalformed: true)
            .trim();
      }
    }
    return null;
  }

  /// 从单帧 HEVC MP4 文件（由 ffmpeg -frames:v 1 -c:v libx265 -tag:v hvc1 生成）提取 hvcC 与帧数据，
  /// 纯 Dart 封装为标准 ISO/IEC 23008-12 原生 .HEIC 文件并内嵌完整 EXIF + Apple MakerNote。
  static Future<void> buildHeicFromHevcMp4({
    required String hevcMp4Path,
    required String outHeicPath,
    required String make,
    required String model,
    required String uuid,
    DateTime? shotAt,
  }) async {
    final mp4Bytes = await File(hevcMp4Path).readAsBytes();
    final (width, height, hvccBox, hevcSample) = _extractHevcFrameFromMp4(mp4Bytes);

    final app1 = buildExifApp1Segment(
      make: make,
      model: model,
      shotAt: shotAt,
      livePhotoUuid: uuid,
      imageWidth: width,
      imageHeight: height,
    );
    final exifPayload = app1.sublist(4); // 从 "Exif\0\0" 开始
    final exifItem = (BytesBuilder()
          ..add([0x00, 0x00, 0x00, 0x06])
          ..add(exifPayload))
        .toBytes();

    final ftyp = _wrapAtom(
      'ftyp',
      Uint8List.fromList([
        ...'heic'.codeUnits,
        0x00, 0x00, 0x00, 0x00,
        ...'mif1'.codeUnits,
        ...'miaf'.codeUnits,
        ...'heic'.codeUnits,
      ]),
    );

    final hdlr = _wrapFullBox(
      'hdlr',
      0,
      0,
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x00,
        ...'pict'.codeUnits,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00,
      ]),
    );

    final pitm = _wrapFullBox(
      'pitm',
      0,
      0,
      Uint8List.fromList([0x00, 0x01]),
    );

    final infe1 = _wrapFullBox(
      'infe',
      2,
      0,
      Uint8List.fromList([
        0x00, 0x01,
        0x00, 0x00,
        ...'hvc1'.codeUnits,
        0x00,
      ]),
    );
    final infe2 = _wrapFullBox(
      'infe',
      2,
      1,
      Uint8List.fromList([
        0x00, 0x02,
        0x00, 0x00,
        ...'Exif'.codeUnits,
        0x00,
      ]),
    );
    final iinf = _wrapFullBox(
      'iinf',
      0,
      0,
      (BytesBuilder()
            ..add([0x00, 0x02])
            ..add(infe1)
            ..add(infe2))
          .toBytes(),
    );

    final cdsc = _wrapAtom(
      'cdsc',
      Uint8List.fromList([
        0x00, 0x02,
        0x00, 0x01,
        0x00, 0x01,
      ]),
    );
    final iref = _wrapFullBox('iref', 0, 0, cdsc);

    final colr = _wrapAtom(
      'colr',
      Uint8List.fromList([
        ...'nclx'.codeUnits,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x06,
        0x80,
      ]),
    );
    final ispeBd = ByteData(8)
      ..setUint32(0, width, Endian.big)
      ..setUint32(4, height, Endian.big);
    final ispe = _wrapFullBox('ispe', 0, 0, ispeBd.buffer.asUint8List());
    final pixi = _wrapFullBox(
      'pixi',
      0,
      0,
      Uint8List.fromList([0x03, 0x08, 0x08, 0x08]),
    );
    final ipco = _wrapAtom(
      'ipco',
      (BytesBuilder()
            ..add(colr)
            ..add(hvccBox)
            ..add(ispe)
            ..add(pixi))
          .toBytes(),
    );
    final ipma = _wrapFullBox(
      'ipma',
      0,
      0,
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x01,
        0x04,
        0x01,
        0x82,
        0x03,
        0x04,
      ]),
    );
    final iprp = _wrapAtom(
      'iprp',
      (BytesBuilder()
            ..add(ipco)
            ..add(ipma))
          .toBytes(),
    );

    const ilocBoxSize = 44;
    final metaTotalSize = 12 +
        hdlr.length +
        pitm.length +
        ilocBoxSize +
        iinf.length +
        iref.length +
        iprp.length;
    final mdatHeaderOffset = ftyp.length + metaTotalSize;
    final hevcOffset = mdatHeaderOffset + 8;
    final exifOffset = hevcOffset + hevcSample.length;

    final ilocBd = ByteData(32)
      ..setUint8(0, 0x44)
      ..setUint8(1, 0x00)
      ..setUint16(2, 2, Endian.big)
      ..setUint16(4, 1, Endian.big)
      ..setUint16(6, 0, Endian.big)
      ..setUint16(8, 1, Endian.big)
      ..setUint32(10, hevcOffset, Endian.big)
      ..setUint32(14, hevcSample.length, Endian.big)
      ..setUint16(18, 2, Endian.big)
      ..setUint16(20, 0, Endian.big)
      ..setUint16(22, 1, Endian.big)
      ..setUint32(24, exifOffset, Endian.big)
      ..setUint32(28, exifItem.length, Endian.big);
    final iloc = _wrapFullBox('iloc', 0, 0, ilocBd.buffer.asUint8List());

    final meta = _wrapFullBox(
      'meta',
      0,
      0,
      (BytesBuilder()
            ..add(hdlr)
            ..add(pitm)
            ..add(iloc)
            ..add(iinf)
            ..add(iref)
            ..add(iprp))
          .toBytes(),
    );

    final mdat = _wrapAtom(
      'mdat',
      (BytesBuilder()
            ..add(hevcSample)
            ..add(exifItem))
          .toBytes(),
    );

    final outHeic = BytesBuilder()
      ..add(ftyp)
      ..add(meta)
      ..add(mdat);
    await File(outHeicPath).writeAsBytes(outHeic.toBytes());
  }

  static (int width, int height, Uint8List hvccBox, Uint8List hevcSample)
      _extractHevcFrameFromMp4(Uint8List b) {
    int width = 0;
    int height = 0;
    Uint8List? hvccBox;
    int sampleOffset = 0;
    int sampleSize = 0;

    void walk(int start, int end) {
      int p = start;
      while (p + 8 <= end) {
        final bd = ByteData.sublistView(b, p, p + 8);
        int sz = bd.getUint32(0);
        final typ = latin1.decode(b.sublist(p + 4, p + 8));
        int hdrLen = 8;
        if (sz == 1 && p + 16 <= end) {
          sz = ByteData.sublistView(b, p + 8, p + 16).getUint64(0);
          hdrLen = 16;
        } else if (sz == 0) {
          sz = end - p;
        }
        if (sz < hdrLen || p + sz > end) break;

        if (typ == 'moov' ||
            typ == 'trak' ||
            typ == 'mdia' ||
            typ == 'minf' ||
            typ == 'stbl') {
          walk(p + hdrLen, p + sz);
        } else if (typ == 'stsd' && p + 16 + 86 <= p + sz) {
          final ep = p + 16;
          final eBd = ByteData.sublistView(b, ep, ep + 36);
          final esz = eBd.getUint32(0);
          width = eBd.getUint16(32);
          height = eBd.getUint16(34);
          int sp = ep + 86;
          final eEnd = (ep + esz <= p + sz) ? ep + esz : p + sz;
          while (sp + 8 <= eEnd) {
            final ssz = ByteData.sublistView(b, sp, sp + 4).getUint32(0);
            final styp = latin1.decode(b.sublist(sp + 4, sp + 8));
            if (ssz < 8 || sp + ssz > eEnd) break;
            if (styp == 'hvcC') {
              hvccBox = b.sublist(sp, sp + ssz);
              break;
            }
            sp += ssz;
          }
        } else if (typ == 'stsz' && p + 20 <= p + sz) {
          final sBd = ByteData.sublistView(b, p + 12, p + sz);
          sampleSize = sBd.getUint32(0);
          if (sampleSize == 0 && p + 24 <= p + sz) {
            sampleSize = sBd.getUint32(8);
          }
        } else if (typ == 'stco' && p + 20 <= p + sz) {
          sampleOffset = ByteData.sublistView(b, p + 16, p + 20).getUint32(0);
        } else if (typ == 'co64' && p + 24 <= p + sz) {
          sampleOffset = ByteData.sublistView(b, p + 16, p + 24).getUint64(0);
        }
        p += sz;
      }
    }

    walk(0, b.length);
    if (hvccBox == null || sampleSize <= 0 || sampleOffset + sampleSize > b.length) {
      throw StateError('无法从临时 HEVC 帧文件中提取有效的 hvcC 或图像码流');
    }
    return (
      width,
      height,
      hvccBox!,
      b.sublist(sampleOffset, sampleOffset + sampleSize),
    );
  }

  /// 从 JPEG 字节流解析 SOF0/SOF2 帧头中的真实图像宽高
  static (int width, int height)? extractJpegDimensions(Uint8List jpg) {
    if (jpg.length < 4 || jpg[0] != 0xFF || jpg[1] != 0xD8) return null;
    int pos = 2;
    while (pos + 9 <= jpg.length) {
      if (jpg[pos] != 0xFF) {
        pos++;
        continue;
      }
      while (pos < jpg.length && jpg[pos] == 0xFF) {
        pos++;
      }
      if (pos >= jpg.length) break;
      final marker = jpg[pos];
      pos++;
      if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
        continue;
      }
      if (marker == 0xDA || pos + 2 > jpg.length) break;
      final segLen = (jpg[pos] << 8) | jpg[pos + 1];
      if (segLen < 2 || pos + segLen > jpg.length) break;
      if ((marker == 0xC0 || marker == 0xC1 || marker == 0xC2) && segLen >= 7) {
        final h = (jpg[pos + 3] << 8) | jpg[pos + 4];
        final w = (jpg[pos + 5] << 8) | jpg[pos + 6];
        if (w > 0 && h > 0) return (w, h);
      }
      pos += segLen;
    }
    return null;
  }

  /// 构造标准 TIFF/EXIF APP1 段（0xFFE1 + "Exif\0\0"），支持写入设备信息、拍摄时间、LONG 型宽高及完整 Apple Live Photo MakerNote
  static Uint8List buildExifApp1Segment({
    required String make,
    required String model,
    String software = 'Pocket Motion',
    DateTime? shotAt,
    String? livePhotoUuid,
    int? imageWidth,
    int? imageHeight,
  }) {
    final shotStr = _formatExifDate(shotAt);

    final hasDate = shotStr != null;
    final numIfd0 = hasDate ? 10 : 9;
    const ifd0Offset = 8;
    final data0Offset = ifd0Offset + 2 + numIfd0 * 12 + 4;

    final ifd0Entries = BytesBuilder();
    final blobs0 = BytesBuilder();

    void addEntry(
      BytesBuilder entries,
      BytesBuilder blobs,
      int baseOffset,
      int tag,
      int type,
      int count,
      Uint8List rawBytes,
    ) {
      final h = ByteData(8)
        ..setUint16(0, tag, Endian.big)
        ..setUint16(2, type, Endian.big)
        ..setUint32(4, count, Endian.big);
      entries.add(h.buffer.asUint8List());

      if (rawBytes.length <= 4) {
        final inlineVal = Uint8List(4);
        inlineVal.setRange(0, rawBytes.length, rawBytes);
        entries.add(inlineVal);
      } else {
        final off = baseOffset + blobs.length;
        final offBd = ByteData(4)..setUint32(0, off, Endian.big);
        entries.add(offBd.buffer.asUint8List());
        blobs.add(rawBytes);
        if (blobs.length.isOdd) blobs.addByte(0);
      }
    }

    void addAscii(
      BytesBuilder entries,
      BytesBuilder blobs,
      int baseOffset,
      int tag,
      String value,
    ) {
      final bytes = Uint8List.fromList([...utf8.encode(value), 0]);
      addEntry(entries, blobs, baseOffset, tag, 2, bytes.length, bytes);
    }

    Uint8List u16(int v) => (ByteData(2)..setUint16(0, v, Endian.big)).buffer.asUint8List();
    Uint8List u32(int v) => (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();
    Uint8List rational(int num, int den) => (ByteData(8)
          ..setUint32(0, num, Endian.big)
          ..setUint32(4, den, Endian.big))
        .buffer
        .asUint8List();

    addAscii(ifd0Entries, blobs0, data0Offset, 0x010F, make);
    addAscii(ifd0Entries, blobs0, data0Offset, 0x0110, model);
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0112, 3, 1, u16(1));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x011A, 5, 1, rational(72, 1));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x011B, 5, 1, rational(72, 1));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0128, 3, 1, u16(2));
    addAscii(ifd0Entries, blobs0, data0Offset, 0x0131, software);
    if (hasDate) {
      addAscii(ifd0Entries, blobs0, data0Offset, 0x0132, shotStr);
    }
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0213, 3, 1, u16(1));

    final exifIfdOffset = data0Offset + blobs0.length;
    addEntry(ifd0Entries, blobs0, data0Offset, 0x8769, 4, 1, u32(exifIfdOffset));

    final hasDims = imageWidth != null && imageHeight != null && imageWidth > 0 && imageHeight > 0;
    int numExif = 3; // 0x9000, 0x9101, 0xA001
    if (hasDate) numExif += 5;
    if (livePhotoUuid != null) numExif += 1;
    if (hasDims) numExif += 2;

    final data1Offset = exifIfdOffset + 2 + numExif * 12 + 4;
    final exifEntries = BytesBuilder();
    final blobs1 = BytesBuilder();

    addEntry(
      exifEntries,
      blobs1,
      data1Offset,
      0x9000,
      7,
      4,
      Uint8List.fromList('0232'.codeUnits),
    );
    if (hasDate) {
      addAscii(exifEntries, blobs1, data1Offset, 0x9003, shotStr);
      addAscii(exifEntries, blobs1, data1Offset, 0x9004, shotStr);
      addAscii(exifEntries, blobs1, data1Offset, 0x9010, '+08:00');
      addAscii(exifEntries, blobs1, data1Offset, 0x9011, '+08:00');
      addAscii(exifEntries, blobs1, data1Offset, 0x9012, '+08:00');
    }
    addEntry(
      exifEntries,
      blobs1,
      data1Offset,
      0x9101,
      7,
      4,
      Uint8List.fromList([1, 2, 3, 0]),
    );
    if (livePhotoUuid != null) {
      final makerNote = _buildAppleMakerNote(livePhotoUuid);
      addEntry(
        exifEntries,
        blobs1,
        data1Offset,
        0x927C,
        7,
        makerNote.length,
        makerNote,
      );
    }
    addEntry(exifEntries, blobs1, data1Offset, 0xA001, 3, 1, u16(1));
    if (hasDims) {
      addEntry(exifEntries, blobs1, data1Offset, 0xA002, 4, 1, u32(imageWidth));
      addEntry(exifEntries, blobs1, data1Offset, 0xA003, 4, 1, u32(imageHeight));
    }

    final tiff = BytesBuilder()
      ..add([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])
      ..add(u16(numIfd0))
      ..add(ifd0Entries.toBytes())
      ..add(u32(0))
      ..add(blobs0.toBytes())
      ..add(u16(numExif))
      ..add(exifEntries.toBytes())
      ..add(u32(0))
      ..add(blobs1.toBytes());

    final payload = BytesBuilder()
      ..add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
      ..add(tiff.toBytes());
    final payloadBytes = payload.toBytes();
    final segLen = payloadBytes.length + 2;

    return (BytesBuilder()
          ..add([0xFF, 0xE1])
          ..add(u16(segLen))
          ..add(payloadBytes))
        .toBytes();
  }

  /// 将 EXIF APP1 段（以及可选的附加段如 XMP APP1）注入到 JPEG 的 SOI (0xFFD8) 之后，并清理旧的 EXIF APP1
  static Uint8List injectIntoJpeg(
    Uint8List jpg,
    List<Uint8List> app1Segments,
  ) {
    if (jpg.length < 2 || jpg[0] != 0xFF || jpg[1] != 0xD8) {
      final out = BytesBuilder();
      for (final seg in app1Segments) {
        out.add(seg);
      }
      out.add(jpg);
      return out.toBytes();
    }

    final out = BytesBuilder()..add([0xFF, 0xD8]);
    for (final seg in app1Segments) {
      out.add(seg);
    }

    int pos = 2;
    while (pos + 4 <= jpg.length && jpg[pos] == 0xFF && jpg[pos + 1] != 0xDA) {
      final marker = jpg[pos + 1];
      if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
        break;
      }
      final segLen = (jpg[pos + 2] << 8) | jpg[pos + 3];
      if (segLen < 2 || pos + 2 + segLen > jpg.length) break;

      bool isOldExif = false;
      if (marker == 0xE1 && pos + 10 <= jpg.length) {
        if (jpg[pos + 4] == 0x45 &&
            jpg[pos + 5] == 0x78 &&
            jpg[pos + 6] == 0x69 &&
            jpg[pos + 7] == 0x66 &&
            jpg[pos + 8] == 0x00 &&
            jpg[pos + 9] == 0x00) {
          isOldExif = true;
        }
      }
      if (!isOldExif) {
        out.add(jpg.sublist(pos, pos + 2 + segLen));
      }
      pos += 2 + segLen;
    }

    if (pos < jpg.length) {
      out.add(jpg.sublist(pos));
    }
    return out.toBytes();
  }

  /// 纯 Dart 为 MOV 写入完整 Apple Live Photo 元数据
  static Future<void> writeMovLivePhotoMetadata({
    required String srcMp4Path,
    required String outMovPath,
    required String uuid,
    required String make,
    required String model,
    DateTime? shotAt,
    double coverTimeSeconds = 1.5,
  }) async {
    final raw = await File(srcMp4Path).readAsBytes();
    final buf = Uint8List.fromList(raw);

    int pos = 0;
    int ftypPos = -1;
    int ftypSize = 0;
    int moovPos = -1;
    int moovSize = 0;
    int moovHdrLen = 8;

    while (pos + 8 <= buf.length) {
      final bd = ByteData.sublistView(buf, pos, pos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(buf.sublist(pos + 4, pos + 8));
      int hdrLen = 8;
      if (sz == 1 && pos + 16 <= buf.length) {
        sz = ByteData.sublistView(buf, pos + 8, pos + 16).getUint64(0);
        hdrLen = 16;
      } else if (sz == 0) {
        sz = buf.length - pos;
      }
      if (sz < hdrLen || pos + sz > buf.length) break;

      if (typ == 'ftyp') {
        ftypPos = pos;
        ftypSize = sz;
      } else if (typ == 'moov') {
        moovPos = pos;
        moovSize = sz;
        moovHdrLen = hdrLen;
        break;
      }
      pos += sz;
    }

    if (moovPos < 0) {
      await File(outMovPath).writeAsBytes(buf);
      return;
    }

    if (ftypPos >= 0 && ftypSize >= 16) {
      buf[ftypPos + 8] = 0x71; // 'q'
      buf[ftypPos + 9] = 0x74; // 't'
      buf[ftypPos + 10] = 0x20; // ' '
      buf[ftypPos + 11] = 0x20; // ' '
    }

    final moovBody = Uint8List.fromList(
      buf.sublist(moovPos + moovHdrLen, moovPos + moovSize),
    );

    final qtSec = shotAt != null
        ? (shotAt.toUtc().millisecondsSinceEpoch ~/ 1000) + _qtEpochOffset
        : 0;

    if (qtSec > 0) {
      _patchMoovTimestamps(moovBody, 0, moovBody.length, qtSec);
    }

    final (movieTimescale, movieDuration, maxTrackId) = _readMvhdInfo(moovBody);
    final videoTiming = _findVideoTrackTiming(
      moovBody,
      fallbackTimescale: movieTimescale,
      fallbackDuration: movieDuration,
    );
    final metaTrackId = maxTrackId + 1;
    _updateMvhdNextTrackId(moovBody, metaTrackId + 1);

    final metaSamplesPayload = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0xFF,
      0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
    ]);
    final metaMdatAtom = _wrapAtom('mdat', metaSamplesPayload);

    final isMoovAtEnd = (moovPos + moovSize == buf.length);
    final int metaChunkFileOffset = isMoovAtEnd
        ? (moovPos + 8)
        : (buf.length + 8);

    final stillImageMetaTrak = _buildStillImageTimeTrak(
      metaTrackId: metaTrackId,
      videoTrackId: videoTiming.trackId,
      qtSec: qtSec,
      movieTimescale: movieTimescale,
      movieDuration: movieDuration,
      videoTimescale: videoTiming.videoTimescale,
      videoDuration: videoTiming.videoDuration,
      frameDelta: videoTiming.frameDelta,
      coverTimeSeconds: coverTimeSeconds,
      metaChunkFileOffset: metaChunkFileOffset,
    );

    final filteredMoovBody = BytesBuilder();
    int bPos = 0;
    while (bPos + 8 <= moovBody.length) {
      final bd = ByteData.sublistView(moovBody, bPos, bPos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(moovBody.sublist(bPos + 4, bPos + 8));
      if (sz == 0) sz = moovBody.length - bPos;
      if (sz < 8 || bPos + sz > moovBody.length) break;

      if (typ == 'mvhd') {
        filteredMoovBody.add(moovBody.sublist(bPos, bPos + sz));
      } else if (typ == 'trak') {
        final handlerSub = _getTrakHandlerSubtype(moovBody, bPos + 8, bPos + sz);
        if (handlerSub == 'vide' || handlerSub == 'soun') {
          filteredMoovBody.add(moovBody.sublist(bPos, bPos + sz));
        }
      }
      bPos += sz;
    }

    filteredMoovBody.add(stillImageMetaTrak);

    final metaAtom = _buildQtMdtaLivePhotoMetaAtom(
      uuid: uuid,
      make: make,
      model: model,
      creationDateIso: shotAt != null ? _formatIso8601WithOffset(shotAt) : null,
    );
    filteredMoovBody.add(metaAtom);

    final newMoovAtom = _wrapAtom('moov', filteredMoovBody.toBytes());

    final out = BytesBuilder();
    if (isMoovAtEnd) {
      out.add(buf.sublist(0, moovPos));
      out.add(metaMdatAtom);
      out.add(newMoovAtom);
    } else {
      buf[moovPos + 4] = 0x66; // 'f'
      buf[moovPos + 5] = 0x72; // 'r'
      buf[moovPos + 6] = 0x65; // 'e'
      buf[moovPos + 7] = 0x65; // 'e'
      out.add(buf);
      out.add(metaMdatAtom);
      out.add(newMoovAtom);
    }

    await File(outMovPath).writeAsBytes(out.toBytes());
  }

  static (int timescale, int duration, int maxTrackId) _readMvhdInfo(Uint8List moovBody) {
    int timescale = 600;
    int duration = 1800;
    int maxTrackId = 2;

    int pos = 0;
    while (pos + 8 <= moovBody.length) {
      final bd = ByteData.sublistView(moovBody, pos, pos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(moovBody.sublist(pos + 4, pos + 8));
      if (sz == 0) sz = moovBody.length - pos;
      if (sz < 8 || pos + sz > moovBody.length) break;

      final bodyStart = pos + 8;
      final bodyEnd = pos + sz;
      if (typ == 'mvhd' && bodyEnd - bodyStart >= 24) {
        final ver = moovBody[bodyStart];
        final mBd = ByteData.sublistView(moovBody, bodyStart, bodyEnd);
        if (ver == 1 && bodyEnd - bodyStart >= 32) {
          timescale = mBd.getUint32(20);
          duration = mBd.getUint64(24);
          if (bodyEnd - bodyStart >= 108) {
            final nextId = mBd.getUint32(104);
            if (nextId > maxTrackId) maxTrackId = nextId - 1;
          }
        } else {
          timescale = mBd.getUint32(12);
          duration = mBd.getUint32(16);
          if (bodyEnd - bodyStart >= 100) {
            final nextId = mBd.getUint32(96);
            if (nextId > maxTrackId) maxTrackId = nextId - 1;
          }
        }
      } else if (typ == 'trak') {
        final tid = _getTrakId(moovBody, bodyStart, bodyEnd);
        if (tid != null && tid > maxTrackId) maxTrackId = tid;
      }
      pos += sz;
    }
    if (timescale <= 0) timescale = 600;
    if (duration <= 0) duration = timescale * 3;
    return (timescale, duration, maxTrackId);
  }

  static void _updateMvhdNextTrackId(Uint8List moovBody, int nextTrackId) {
    int pos = 0;
    while (pos + 8 <= moovBody.length) {
      final bd = ByteData.sublistView(moovBody, pos, pos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(moovBody.sublist(pos + 4, pos + 8));
      if (sz == 0) sz = moovBody.length - pos;
      if (sz < 8 || pos + sz > moovBody.length) break;
      final bodyStart = pos + 8;
      final bodyEnd = pos + sz;
      if (typ == 'mvhd') {
        final ver = moovBody[bodyStart];
        final mBd = ByteData.sublistView(moovBody, bodyStart, bodyEnd);
        if (ver == 1 && bodyEnd - bodyStart >= 108) {
          mBd.setUint32(104, nextTrackId, Endian.big);
        } else if (ver == 0 && bodyEnd - bodyStart >= 100) {
          mBd.setUint32(96, nextTrackId, Endian.big);
        }
        break;
      }
      pos += sz;
    }
  }

  static int? _getTrakId(Uint8List buf, int start, int end) {
    int pos = start;
    while (pos + 8 <= end) {
      final sz = ByteData.sublistView(buf, pos, pos + 4).getUint32(0);
      final typ = latin1.decode(buf.sublist(pos + 4, pos + 8));
      if (sz < 8 || pos + sz > end) break;
      if (typ == 'tkhd' && sz >= 24) {
        final ver = buf[pos + 8];
        final bd = ByteData.sublistView(buf, pos + 8, pos + sz);
        return ver == 1 && sz >= 32 ? bd.getUint32(20) : bd.getUint32(12);
      }
      pos += sz;
    }
    return null;
  }

  static String? _getTrakHandlerSubtype(Uint8List buf, int start, int end) {
    int pos = start;
    while (pos + 8 <= end) {
      int sz = ByteData.sublistView(buf, pos, pos + 4).getUint32(0);
      final typ = latin1.decode(buf.sublist(pos + 4, pos + 8));
      if (sz == 0) sz = end - pos;
      if (sz < 8 || pos + sz > end) break;
      if (typ == 'mdia') {
        int mPos = pos + 8;
        final mEnd = pos + sz;
        while (mPos + 8 <= mEnd) {
          int mSz = ByteData.sublistView(buf, mPos, mPos + 4).getUint32(0);
          final mTyp = latin1.decode(buf.sublist(mPos + 4, mPos + 8));
          if (mSz == 0) mSz = mEnd - mPos;
          if (mSz < 8 || mPos + mSz > mEnd) break;
          if (mTyp == 'hdlr' && mSz >= 20) {
            return latin1.decode(buf.sublist(mPos + 16, mPos + 20));
          }
          mPos += mSz;
        }
      }
      pos += sz;
    }
    return null;
  }

  static _VideoTrackTiming _findVideoTrackTiming(
    Uint8List moovBody, {
    required int fallbackTimescale,
    required int fallbackDuration,
  }) {
    int pos = 0;
    while (pos + 8 <= moovBody.length) {
      int sz = ByteData.sublistView(moovBody, pos, pos + 4).getUint32(0);
      final typ = latin1.decode(moovBody.sublist(pos + 4, pos + 8));
      if (sz == 0) sz = moovBody.length - pos;
      if (sz < 8 || pos + sz > moovBody.length) break;

      if (typ == 'trak') {
        final sub = _getTrakHandlerSubtype(moovBody, pos + 8, pos + sz);
        if (sub == 'vide') {
          final trackId = _getTrakId(moovBody, pos + 8, pos + sz) ?? 1;
          int vTimescale = fallbackTimescale;
          int vDuration = fallbackDuration;
          int frameDelta = (fallbackTimescale / 30).round();

          void scanMdia(int s, int e) {
            int p = s;
            while (p + 8 <= e) {
              int aSz = ByteData.sublistView(moovBody, p, p + 4).getUint32(0);
              final aTyp = latin1.decode(moovBody.sublist(p + 4, p + 8));
              if (aSz == 0) aSz = e - p;
              if (aSz < 8 || p + aSz > e) break;
              final bStart = p + 8;
              final bEnd = p + aSz;
              if (aTyp == 'mdhd' && bEnd - bStart >= 20) {
                final ver = moovBody[bStart];
                final bd = ByteData.sublistView(moovBody, bStart, bEnd);
                if (ver == 1 && bEnd - bStart >= 32) {
                  vTimescale = bd.getUint32(20);
                  vDuration = bd.getUint64(24);
                } else {
                  vTimescale = bd.getUint32(12);
                  vDuration = bd.getUint32(16);
                }
              } else if (aTyp == 'stts' && bEnd - bStart >= 16) {
                final bd = ByteData.sublistView(moovBody, bStart, bEnd);
                final entryCount = bd.getUint32(4);
                if (entryCount >= 1) {
                  final delta = bd.getUint32(12);
                  if (delta > 0) frameDelta = delta;
                }
              } else if (aTyp == 'mdia' || aTyp == 'minf' || aTyp == 'stbl') {
                scanMdia(bStart, bEnd);
              }
              p += aSz;
            }
          }

          scanMdia(pos + 8, pos + sz);
          if (vTimescale <= 0) vTimescale = 600;
          if (frameDelta <= 0) frameDelta = (vTimescale / 30).round().clamp(1, vTimescale);
          if (vDuration <= frameDelta * 2) vDuration = vTimescale * 3;
          return _VideoTrackTiming(
            trackId: trackId,
            videoTimescale: vTimescale,
            videoDuration: vDuration,
            frameDelta: frameDelta,
          );
        }
      }
      pos += sz;
    }

    final defaultDelta = (fallbackTimescale / 30).round().clamp(1, fallbackTimescale);
    return _VideoTrackTiming(
      trackId: 1,
      videoTimescale: fallbackTimescale,
      videoDuration: fallbackDuration,
      frameDelta: defaultDelta,
    );
  }

  /// 构造 Apple Live Photo 必需的 com.apple.quicktime.still-image-time (mebx) 定时元数据轨
  static Uint8List _buildStillImageTimeTrak({
    required int metaTrackId,
    required int videoTrackId,
    required int qtSec,
    required int movieTimescale,
    required int movieDuration,
    required int videoTimescale,
    required int videoDuration,
    required int frameDelta,
    required double coverTimeSeconds,
    required int metaChunkFileOffset,
  }) {
    final totalFrames = (videoDuration / frameDelta).floor();
    final targetFrame = ((coverTimeSeconds * videoTimescale) / frameDelta).round();
    final clampedFrame = totalFrames > 2
        ? targetFrame.clamp(1, totalFrames - 2)
        : 1;
    final int coverTicks = (clampedFrame * frameDelta).clamp(
      frameDelta,
      videoDuration > frameDelta * 2 ? videoDuration - frameDelta * 2 : frameDelta,
    );
    final int oneFrameTicks = frameDelta;
    final int tailTicks = (videoDuration - coverTicks - oneFrameTicks).clamp(
      frameDelta,
      videoDuration,
    );
    final int totalMetaVideoTicks = coverTicks + oneFrameTicks + tailTicks;

    final tkhdPayload = ByteData(84)
      ..setUint32(0, 0x0000000F, Endian.big)
      ..setUint32(4, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(8, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(12, metaTrackId, Endian.big)
      ..setUint32(16, 0, Endian.big)
      ..setUint32(20, movieDuration, Endian.big)
      ..setUint32(44, 0x00010000, Endian.big)
      ..setUint32(60, 0x00010000, Endian.big)
      ..setUint32(72, 0x40000000, Endian.big);
    final tkhdAtom = _wrapAtom('tkhd', tkhdPayload.buffer.asUint8List());

    final cdscPayload = ByteData(4)..setUint32(0, videoTrackId, Endian.big);
    final cdscAtom = _wrapAtom('cdsc', cdscPayload.buffer.asUint8List());
    final trefAtom = _wrapAtom('tref', cdscAtom);

    final elstPayload = ByteData(20)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, 1, Endian.big)
      ..setUint32(8, movieDuration, Endian.big)
      ..setUint32(12, 0, Endian.big)
      ..setUint32(16, 0x00010000, Endian.big);
    final elstAtom = _wrapAtom('elst', elstPayload.buffer.asUint8List());
    final edtsAtom = _wrapAtom('edts', elstAtom);

    final mdhdPayload = ByteData(24)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(8, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(12, videoTimescale, Endian.big)
      ..setUint32(16, totalMetaVideoTicks, Endian.big)
      ..setUint16(20, 0x55C4, Endian.big)
      ..setUint16(22, 0, Endian.big);
    final mdhdAtom = _wrapAtom('mdhd', mdhdPayload.buffer.asUint8List());

    final mdiaHdlrAtom = _wrapAtom(
      'hdlr',
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x00,
        0x6D, 0x68, 0x6C, 0x72,
        0x6D, 0x65, 0x74, 0x61,
        0x61, 0x70, 0x70, 0x6C,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x13,
        ...'Core Media Metadata'.codeUnits,
      ]),
    );

    final gmhdAtom = _wrapAtom(
      'gmhd',
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18,
        0x67, 0x6D, 0x69, 0x6E,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x40, 0x80, 0x00,
        0x80, 0x00, 0x80, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ]),
    );

    final minfHdlrAtom = _wrapAtom(
      'hdlr',
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x00,
        0x64, 0x68, 0x6C, 0x72,
        0x61, 0x6C, 0x69, 0x73,
        0x61, 0x70, 0x70, 0x6C,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x17,
        ...'Core Media Data Handler'.codeUnits,
      ]),
    );

    final dinfAtom = _wrapAtom(
      'dinf',
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x1C,
        0x64, 0x72, 0x65, 0x66,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x0C,
        0x61, 0x6C, 0x69, 0x73,
        0x00, 0x00, 0x00, 0x01,
      ]),
    );

    final stsdAtom = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x70, 0x73, 0x74, 0x73, 0x64,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x60, 0x6D, 0x65, 0x62, 0x78,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x50, 0x6B, 0x65, 0x79, 0x73,
      0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x30, 0x6B, 0x65, 0x79, 0x64,
      0x6D, 0x64, 0x74, 0x61,
      ...'com.apple.quicktime.still-image-time'.codeUnits,
      0x00, 0x00, 0x00, 0x10, 0x64, 0x74, 0x79, 0x70,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41,
    ]);

    final sttsPayload = ByteData(32)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, 3, Endian.big)
      ..setUint32(8, 1, Endian.big)
      ..setUint32(12, coverTicks, Endian.big)
      ..setUint32(16, 1, Endian.big)
      ..setUint32(20, oneFrameTicks, Endian.big)
      ..setUint32(24, 1, Endian.big)
      ..setUint32(28, tailTicks, Endian.big);
    final sttsAtom = _wrapAtom('stts', sttsPayload.buffer.asUint8List());

    final stscPayload = ByteData(20)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, 1, Endian.big)
      ..setUint32(8, 1, Endian.big)
      ..setUint32(12, 3, Endian.big)
      ..setUint32(16, 1, Endian.big);
    final stscAtom = _wrapAtom('stsc', stscPayload.buffer.asUint8List());

    final stszPayload = ByteData(24)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, 0, Endian.big)
      ..setUint32(8, 3, Endian.big)
      ..setUint32(12, 8, Endian.big)
      ..setUint32(16, 9, Endian.big)
      ..setUint32(20, 8, Endian.big);
    final stszAtom = _wrapAtom('stsz', stszPayload.buffer.asUint8List());

    final stcoPayload = ByteData(12)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, 1, Endian.big)
      ..setUint32(8, metaChunkFileOffset, Endian.big);
    final stcoAtom = _wrapAtom('stco', stcoPayload.buffer.asUint8List());

    final stblAtom = _wrapAtom(
      'stbl',
      (BytesBuilder()
            ..add(stsdAtom)
            ..add(sttsAtom)
            ..add(stscAtom)
            ..add(stszAtom)
            ..add(stcoAtom))
          .toBytes(),
    );

    final minfAtom = _wrapAtom(
      'minf',
      (BytesBuilder()
            ..add(gmhdAtom)
            ..add(minfHdlrAtom)
            ..add(dinfAtom)
            ..add(stblAtom))
          .toBytes(),
    );

    final mdiaAtom = _wrapAtom(
      'mdia',
      (BytesBuilder()
            ..add(mdhdAtom)
            ..add(mdiaHdlrAtom)
            ..add(minfAtom))
          .toBytes(),
    );

    return _wrapAtom(
      'trak',
      (BytesBuilder()
            ..add(tkhdAtom)
            ..add(trefAtom)
            ..add(edtsAtom)
            ..add(mdiaAtom))
          .toBytes(),
    );
  }

  static void _patchMoovTimestamps(Uint8List buf, int start, int end, int qtSec) {
    int pos = start;
    while (pos + 8 <= end) {
      final bd = ByteData.sublistView(buf, pos, pos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(buf.sublist(pos + 4, pos + 8));
      if (sz == 0) sz = end - pos;
      if (sz < 8 || pos + sz > end) break;

      final bodyStart = pos + 8;
      final bodyEnd = pos + sz;

      if (typ == 'mvhd' || typ == 'tkhd' || typ == 'mdhd') {
        if (bodyEnd - bodyStart >= 12) {
          final ver = buf[bodyStart];
          final mBd = ByteData.sublistView(buf, bodyStart, bodyEnd);
          if (ver == 1 && bodyEnd - bodyStart >= 28) {
            mBd.setUint64(4, qtSec, Endian.big);
            mBd.setUint64(12, qtSec, Endian.big);
          } else if (ver == 0 && bodyEnd - bodyStart >= 12) {
            mBd.setUint32(4, qtSec & 0xFFFFFFFF, Endian.big);
            mBd.setUint32(8, qtSec & 0xFFFFFFFF, Endian.big);
          }
        }
      } else if (typ == 'trak' || typ == 'mdia') {
        _patchMoovTimestamps(buf, bodyStart, bodyEnd, qtSec);
      }
      pos += sz;
    }
  }

  static Uint8List _buildQtMdtaLivePhotoMetaAtom({
    required String uuid,
    required String make,
    required String model,
    String? creationDateIso,
  }) {
    final hdlrPayload = Uint8List(24);
    hdlrPayload[8] = 0x6D;
    hdlrPayload[9] = 0x64;
    hdlrPayload[10] = 0x74;
    hdlrPayload[11] = 0x61;
    final hdlrAtom = _wrapAtom('hdlr', hdlrPayload);

    final items = <(String, int, Uint8List)>[
      (
        'com.apple.quicktime.content.identifier',
        1,
        Uint8List.fromList(utf8.encode(uuid)),
      ),
      (
        'com.apple.quicktime.make',
        1,
        Uint8List.fromList(utf8.encode(make)),
      ),
      (
        'com.apple.quicktime.model',
        1,
        Uint8List.fromList(utf8.encode(model)),
      ),
      if (creationDateIso != null)
        (
          'com.apple.quicktime.creationdate',
          1,
          Uint8List.fromList(utf8.encode(creationDateIso)),
        ),
      (
        'com.apple.quicktime.live-photo.auto',
        21,
        Uint8List.fromList([0x01]),
      ),
      (
        'com.apple.quicktime.live-photo.vitality-score',
        23,
        Uint8List.fromList([0x3F, 0x80, 0x00, 0x00]),
      ),
      (
        'com.apple.quicktime.live-photo.vitality-scoring-version',
        21,
        Uint8List.fromList([0x00, 0x00, 0x00, 0x04]),
      ),
    ];

    final keysPayload = BytesBuilder();
    final keysHdr = ByteData(8)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, items.length, Endian.big);
    keysPayload.add(keysHdr.buffer.asUint8List());

    final ilstPayload = BytesBuilder();

    for (var i = 0; i < items.length; i++) {
      final idx = i + 1;
      final keyBytes = utf8.encode(items[i].$1);
      final dataType = items[i].$2;
      final valBytes = items[i].$3;

      final keyHeader = ByteData(8)
        ..setUint32(0, keyBytes.length + 8, Endian.big)
        ..setUint8(4, 0x6D)
        ..setUint8(5, 0x64)
        ..setUint8(6, 0x74)
        ..setUint8(7, 0x61);
      keysPayload.add(keyHeader.buffer.asUint8List());
      keysPayload.add(keyBytes);

      final dataPrefix = ByteData(8)
        ..setUint32(0, dataType, Endian.big)
        ..setUint32(4, 0, Endian.big);
      final dataPayload = BytesBuilder()
        ..add(dataPrefix.buffer.asUint8List())
        ..add(valBytes);
      final dataAtom = _wrapAtom('data', dataPayload.toBytes());

      final itemAtom = ByteData(8)
        ..setUint32(0, dataAtom.length + 8, Endian.big)
        ..setUint32(4, idx, Endian.big);
      ilstPayload.add(itemAtom.buffer.asUint8List());
      ilstPayload.add(dataAtom);
    }

    final keysAtom = _wrapAtom('keys', keysPayload.toBytes());
    final ilstAtom = _wrapAtom('ilst', ilstPayload.toBytes());

    final metaPayload = BytesBuilder()
      ..add(hdlrAtom)
      ..add(keysAtom)
      ..add(ilstAtom);
    return _wrapAtom('meta', metaPayload.toBytes());
  }

  static Uint8List _wrapAtom(String type, Uint8List payload) {
    final hdr = ByteData(8)
      ..setUint32(0, payload.length + 8, Endian.big)
      ..setUint8(4, type.codeUnitAt(0))
      ..setUint8(5, type.codeUnitAt(1))
      ..setUint8(6, type.codeUnitAt(2))
      ..setUint8(7, type.codeUnitAt(3));
    return (BytesBuilder()
          ..add(hdr.buffer.asUint8List())
          ..add(payload))
        .toBytes();
  }

  static Uint8List _wrapFullBox(String type, int version, int flags, Uint8List payload) {
    final vf = ByteData(4)
      ..setUint32(0, ((version & 0xFF) << 24) | (flags & 0xFFFFFF), Endian.big);
    return _wrapAtom(
      type,
      (BytesBuilder()
            ..add(vf.buffer.asUint8List())
            ..add(payload))
          .toBytes(),
    );
  }

  static Uint8List _buildAppleMakerNote(String uuid) {
    const runTimeBplist = <int>[
      98, 112, 108, 105, 115, 116, 48, 48, 212, 1, 2, 3, 4, 5, 6, 7, 8, 85,
      101, 112, 111, 99, 104, 85, 102, 108, 97, 103, 115, 89, 116, 105, 109,
      101, 115, 99, 97, 108, 101, 85, 118, 97, 108, 117, 101, 16, 0, 16, 1,
      17, 2, 88, 17, 3, 132, 8, 17, 23, 29, 39, 45, 47, 49, 52, 0, 0, 0, 0,
      0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 55,
    ];

    const numEntries = 6;
    const dataStart = 14 + 2 + numEntries * 12 + 4; // 92

    final entries = BytesBuilder();
    final blobs = BytesBuilder();

    void addMnEntry(int tag, int type, int count, Uint8List rawBytes) {
      final h = ByteData(8)
        ..setUint16(0, tag, Endian.big)
        ..setUint16(2, type, Endian.big)
        ..setUint32(4, count, Endian.big);
      entries.add(h.buffer.asUint8List());
      if (rawBytes.length <= 4) {
        final val = Uint8List(4)..setRange(0, rawBytes.length, rawBytes);
        entries.add(val);
      } else {
        final off = dataStart + blobs.length;
        final offBd = ByteData(4)..setUint32(0, off, Endian.big);
        entries.add(offBd.buffer.asUint8List());
        blobs.add(rawBytes);
        if (blobs.length.isOdd) blobs.addByte(0);
      }
    }

    Uint8List s32(int v) => (ByteData(4)..setInt32(0, v, Endian.big)).buffer.asUint8List();

    final accelBytes = ByteData(24)
      ..setInt32(0, 0, Endian.big)
      ..setInt32(4, 1, Endian.big)
      ..setInt32(8, -1, Endian.big)
      ..setInt32(12, 1, Endian.big)
      ..setInt32(16, 0, Endian.big)
      ..setInt32(20, 1, Endian.big);

    final uuidBytes = Uint8List.fromList([...uuid.codeUnits, 0]);

    addMnEntry(0x0001, 9, 1, s32(14));
    addMnEntry(0x0003, 7, runTimeBplist.length, Uint8List.fromList(runTimeBplist));
    addMnEntry(0x0008, 10, 3, accelBytes.buffer.asUint8List());
    addMnEntry(0x0011, 2, uuidBytes.length, uuidBytes);
    addMnEntry(0x0014, 9, 1, s32(10));
    addMnEntry(0x0017, 9, 1, s32(900));

    final b = BytesBuilder()
      ..add([
        0x41, 0x70, 0x70, 0x6C, 0x65, 0x20, 0x69, 0x4F, 0x53, 0x00,
        0x00, 0x01, 0x4D, 0x4D,
      ])
      ..add((ByteData(2)..setUint16(0, numEntries, Endian.big)).buffer.asUint8List())
      ..add(entries.toBytes())
      ..add([0x00, 0x00, 0x00, 0x00])
      ..add(blobs.toBytes());

    return b.toBytes();
  }

  static String? _formatExifDate(DateTime? dt) => dt == null
      ? null
      : '${dt.year.toString().padLeft(4, '0')}:'
          '${dt.month.toString().padLeft(2, '0')}:'
          '${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';

  static String _formatIso8601WithOffset(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}T'
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}+08:00';
}
