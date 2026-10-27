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

/// 纯 Dart 跨平台媒体元数据引擎（不依赖外部 Perl / exiftool 进程，彻底杜绝 Windows 中文路径与运行库缺失问题）：
/// 1. 从源 MP4 提取真实设备品牌/型号、拍摄时间与 GPS 信息；
/// 2. 直接构造标准 TIFF/EXIF APP1 段（含 IFD0、ExifIFD 及 Apple iOS MakerNote 0x0011 ContentIdentifier）写入 JPG；
/// 3. 直接在 MOV/MP4 的 moov 原子中更新 mvhd/tkhd/mdhd 时间戳并注入 Apple QuickTime mdta (Keys:ContentIdentifier / Make / Model / CreationDate)。
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
          // 定位顶层 moov 原子（无论在文件开头还是末尾）
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

          // 若 moov 中无显式型号，扫描文件前部 256KB 查找相机型号标识
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
          // QuickTime meta 可能无 version/flags，也可能带 4 字节 version/flags
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

  /// 构造标准 TIFF/EXIF APP1 段（0xFFE1 + "Exif\0\0"），支持写入设备信息、拍摄时间及 Apple Live Photo ContentIdentifier
  static Uint8List buildExifApp1Segment({
    required String make,
    required String model,
    String software = 'Pocket Motion',
    DateTime? shotAt,
    String? livePhotoUuid,
  }) {
    final shotStr = _formatExifDate(shotAt);

    // IFD0 条目（按 Tag 升序排列）
    // 0x010F Make, 0x0110 Model, 0x0112 Orientation, 0x011A XRes, 0x011B YRes,
    // 0x0128 ResUnit, 0x0131 Software, [0x0132 DateTime], 0x0213 YCbCrPositioning, 0x8769 ExifOffset
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

    // ExifIFD 条目（按 Tag 升序排列）
    // 0x9000 ExifVersion
    // [0x9003 DateTimeOriginal, 0x9004 DateTimeDigitized, 0x9010 OffsetTime, 0x9011 OffsetTimeOriginal, 0x9012 OffsetTimeDigitized]
    // 0x9101 ComponentsConfiguration
    // [0x927C MakerNote (Apple Live Photo ContentIdentifier)]
    // 0xA001 ColorSpace
    int numExif = 3; // 0x9000, 0x9101, 0xA001
    if (hasDate) numExif += 5;
    if (livePhotoUuid != null) numExif += 1;

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

    final tiff = BytesBuilder()
      ..add([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]) // "MM\0*\0\0\0\x08"
      ..add(u16(numIfd0))
      ..add(ifd0Entries.toBytes())
      ..add(u32(0))
      ..add(blobs0.toBytes())
      ..add(u16(numExif))
      ..add(exifEntries.toBytes())
      ..add(u32(0))
      ..add(blobs1.toBytes());

    final payload = BytesBuilder()
      ..add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
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

    // 跳过旧的 Exif APP1 段（避免重复 APP1 Exif 冲突）
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

  /// 纯 Dart 为 MOV/MP4 写入 Apple Live Photo QuickTime 元数据（Keys:ContentIdentifier / Make / Model / CreationDate）
  /// 并同步更新 mvhd / tkhd / mdhd 拍摄时间戳，不改变 mdat 偏移（零重编码、零外部进程依赖）。
  static Future<void> writeMovLivePhotoMetadata({
    required String srcMp4Path,
    required String outMovPath,
    required String uuid,
    required String make,
    required String model,
    DateTime? shotAt,
  }) async {
    final raw = await File(srcMp4Path).readAsBytes();
    final buf = Uint8List.fromList(raw);

    int pos = 0;
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

      if (typ == 'moov') {
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

    final moovBody = Uint8List.fromList(
      buf.sublist(moovPos + moovHdrLen, moovPos + moovSize),
    );

    // 1. 更新 moov 内 mvhd / tkhd / mdhd 的创建时间与修改时间
    if (shotAt != null) {
      final unixSec = shotAt.toUtc().millisecondsSinceEpoch ~/ 1000;
      final qtSec = unixSec + _qtEpochOffset;
      _patchMoovTimestamps(moovBody, 0, moovBody.length, qtSec);
    }

    // 2. 过滤掉 moov 顶层旧的 meta 原子，避免与新注入的 QuickTime mdta meta 冲突
    final filteredMoovBody = BytesBuilder();
    int bPos = 0;
    while (bPos + 8 <= moovBody.length) {
      final bd = ByteData.sublistView(moovBody, bPos, bPos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(moovBody.sublist(bPos + 4, bPos + 8));
      if (sz == 0) sz = moovBody.length - bPos;
      if (sz < 8 || bPos + sz > moovBody.length) break;
      if (typ != 'meta') {
        filteredMoovBody.add(moovBody.sublist(bPos, bPos + sz));
      }
      bPos += sz;
    }

    // 3. 构造标准 Apple QuickTime mdta meta 原子
    final kvPairs = <(String, String)>[
      ('com.apple.quicktime.content.identifier', uuid),
      ('com.apple.quicktime.make', make),
      ('com.apple.quicktime.model', model),
      if (shotAt != null)
        ('com.apple.quicktime.creationdate', _formatIso8601WithOffset(shotAt)),
    ];
    final metaAtom = _buildQtMdtaMetaAtom(kvPairs);
    filteredMoovBody.add(metaAtom);

    final newMoovPayload = filteredMoovBody.toBytes();
    final newMoovAtom = _wrapAtom('moov', newMoovPayload);

    final out = BytesBuilder();
    final isMoovAtEnd = (moovPos + moovSize == buf.length);
    if (isMoovAtEnd) {
      // moov 本就在文件末尾：直接替换末尾 moov
      out.add(buf.sublist(0, moovPos));
      out.add(newMoovAtom);
    } else {
      // moov 在 mdat 之前：将原位置 moov 改为等长 free 原子以保持 mdat 偏移不变，并在文件末尾追加新 moov
      buf[moovPos + 4] = 0x66; // 'f'
      buf[moovPos + 5] = 0x72; // 'r'
      buf[moovPos + 6] = 0x65; // 'e'
      buf[moovPos + 7] = 0x65; // 'e'
      out.add(buf);
      out.add(newMoovAtom);
    }

    await File(outMovPath).writeAsBytes(out.toBytes());
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

  static Uint8List _buildQtMdtaMetaAtom(List<(String, String)> kvPairs) {
    // hdlr: 32 bytes ('hdlr', version/flags=0, component_type=0, subtype='mdta', reserved=12B)
    final hdlrPayload = Uint8List(24);
    hdlrPayload[8] = 0x6D; // 'm'
    hdlrPayload[9] = 0x64; // 'd'
    hdlrPayload[10] = 0x74; // 't'
    hdlrPayload[11] = 0x61; // 'a'
    final hdlrAtom = _wrapAtom('hdlr', hdlrPayload);

    final keysPayload = BytesBuilder();
    final keysHdr = ByteData(8)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, kvPairs.length, Endian.big);
    keysPayload.add(keysHdr.buffer.asUint8List());

    final ilstPayload = BytesBuilder();

    for (var i = 0; i < kvPairs.length; i++) {
      final idx = i + 1;
      final keyBytes = utf8.encode(kvPairs[i].$1);
      final valBytes = utf8.encode(kvPairs[i].$2);

      final keyHeader = ByteData(8)
        ..setUint32(0, keyBytes.length + 8, Endian.big)
        ..setUint8(4, 0x6D) // 'm'
        ..setUint8(5, 0x64) // 'd'
        ..setUint8(6, 0x74) // 't'
        ..setUint8(7, 0x61); // 'a'
      keysPayload.add(keyHeader.buffer.asUint8List());
      keysPayload.add(keyBytes);

      final dataPrefix = ByteData(8)
        ..setUint32(0, 1, Endian.big) // type = 1 (UTF-8 text)
        ..setUint32(4, 0, Endian.big); // locale = 0
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

  /// 构造包含 Tag 0x0011 (ContentIdentifier) 的最小 Apple iOS MakerNote 二进制块（70 字节）
  static Uint8List _buildAppleMakerNote(String uuid) {
    final b = BytesBuilder();
    // "Apple iOS\0\0\x01MM"
    b.add([
      0x41, 0x70, 0x70, 0x6C, 0x65, 0x20, 0x69, 0x4F, 0x53, 0x00,
      0x00, 0x01, 0x4D, 0x4D,
    ]);
    // Entry count = 1, Tag = 0x0011, Type = 2 (ASCII), Count = 37, Offset = 32, NextIFD = 0
    b.add([
      0x00, 0x01,
      0x00, 0x11,
      0x00, 0x02,
      0x00, 0x00, 0x00, 0x25,
      0x00, 0x00, 0x00, 0x20,
      0x00, 0x00, 0x00, 0x00,
    ]);
    b.add(uuid.codeUnits);
    b.add([0x00, 0x00]);
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
