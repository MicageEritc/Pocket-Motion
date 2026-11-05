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
              if (parsed.make.isNotEmpty) make = parsed.make;
              if (parsed.model.isNotEmpty) model = parsed.model;
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

  /// 从单帧 HEVC MP4 文件（由 ffmpeg -frames:v 1 -c:v libx265 -profile:v main -tag:v hvc1 生成）提取 hvcC 与帧数据，
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
    final (width, height, rawHvccBox, rawHevcSample) = _extractHevcFrameFromMp4(mp4Bytes);
    final hvccBox = _sanitizeHvccBoxForHeic(rawHvccBox);
    final hevcSample = _stripNonSliceNalsFromHevcSample(rawHevcSample);

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

    // 与 macOS/iOS 原生 ImageIO 生成的 .HEIC 保持完全一致的 ftyp 品牌头
    final ftyp = _wrapAtom(
      'ftyp',
      Uint8List.fromList([
        ...'heic'.codeUnits,
        0x00, 0x00, 0x00, 0x00,
        ...'mif1'.codeUnits,
        ...'MiPr'.codeUnits,
        ...'miaf'.codeUnits,
        ...'MiHB'.codeUnits,
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

    // Apple 原生 HEIC 必备的 dinf -> dref -> url (flags=1) 盒
    final dinf = _wrapAtom(
      'dinf',
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x1C,
        ...'dref'.codeUnits,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x0C,
        ...'url '.codeUnits,
        0x00, 0x00, 0x00, 0x01,
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
    final irot = _wrapAtom('irot', Uint8List.fromList([0x00]));
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
            ..add(irot)
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
        0x05,
        0x81,
        0x82,
        0x03,
        0x84,
        0x05,
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
        dinf.length +
        pitm.length +
        iinf.length +
        iref.length +
        iprp.length +
        ilocBoxSize;
    final mdatHeaderOffset = ftyp.length + metaTotalSize;
    final exifOffset = mdatHeaderOffset + 8;
    final hevcOffset = exifOffset + exifItem.length;

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
            ..add(dinf)
            ..add(pitm)
            ..add(iinf)
            ..add(iref)
            ..add(iprp)
            ..add(iloc))
          .toBytes(),
    );

    final mdat = _wrapAtom(
      'mdat',
      (BytesBuilder()
            ..add(exifItem)
            ..add(hevcSample))
          .toBytes(),
    );

    final outHeic = BytesBuilder()
      ..add(ftyp)
      ..add(meta)
      ..add(mdat);
    await File(outHeicPath).writeAsBytes(outHeic.toBytes());
  }

  /// 规范化 hvcC 盒以严格满足 ISO/IEC 23008-12 (HEIF) 规范与 Apple 硬件解码器要求：
  /// 1. 若 profile_idc 为 4 (Main-Intra / RExt)，修正为 1 (Main Profile) 并开启 Main/MainStillPicture 兼容位；
  /// 2. 仅保留 VPS(32)、SPS(33)、PPS(34) 参数集数组，并强制将每个数组的 array_completeness 设为 1 (0x80 | nalType)。
  static Uint8List _sanitizeHvccBoxForHeic(Uint8List hvccBox) {
    if (hvccBox.length < 31) return hvccBox;
    final payload = Uint8List.fromList(hvccBox.sublist(8));
    final profileIdc = payload[1] & 0x1F;
    if (profileIdc != 1 && profileIdc != 2 && profileIdc != 3) {
      payload[1] = (payload[1] & 0xE0) | 0x01; // Main Profile
      payload[2] |= 0x60; // Main + Main 10 compatibility
    }

    final numArrays = payload[22];
    int p = 23;
    final keptArrays = <Uint8List>[];
    for (int i = 0; i < numArrays && p + 3 <= payload.length; i++) {
      final nalType = payload[p] & 0x3F;
      final numNalus = (payload[p + 1] << 8) | payload[p + 2];
      final arrStart = p;
      p += 3;
      bool valid = true;
      for (int j = 0; j < numNalus; j++) {
        if (p + 2 > payload.length) {
          valid = false;
          break;
        }
        final nlen = (payload[p] << 8) | payload[p + 1];
        p += 2 + nlen;
        if (p > payload.length) {
          valid = false;
          break;
        }
      }
      if (!valid) break;
      if (nalType == 32 || nalType == 33 || nalType == 34) {
        final arrBytes = Uint8List.fromList(payload.sublist(arrStart, p));
        arrBytes[0] = 0x80 | nalType; // array_completeness = 1
        keptArrays.add(arrBytes);
      }
    }

    if (keptArrays.isEmpty) return hvccBox;
    final outPayload = BytesBuilder()
      ..add(payload.sublist(0, 22))
      ..addByte(keptArrays.length);
    for (final arr in keptArrays) {
      outPayload.add(arr);
    }
    return _wrapAtom('hvcC', outPayload.toBytes());
  }

  /// 清理 HEVC 帧样本中的非图像切片 NAL（如 AUD=35 或 PREFIX_SEI=39），仅保留切片 NAL（如 IDR_W_RADL=19 / IDR_N_LP=20）
  static Uint8List _stripNonSliceNalsFromHevcSample(Uint8List sample) {
    final sliceNals = BytesBuilder();
    int p = 0;
    while (p + 4 <= sample.length) {
      final nlen = ByteData.sublistView(sample, p, p + 4).getUint32(0);
      if (nlen <= 0 || p + 4 + nlen > sample.length) break;
      final nalType = (sample[p + 4] >> 1) & 0x3F;
      // 0..31 为 VCL 图像切片 NAL（其中 16..21 为 BLA/IDR/CRA 关键帧切片）
      if (nalType <= 31) {
        sliceNals.add(sample.sublist(p, p + 4 + nlen));
      }
      p += 4 + nlen;
    }
    final cleaned = sliceNals.toBytes();
    return cleaned.isNotEmpty ? cleaned : sample;
  }

  /// 按独立 trak 作用域提取包含 hvcC 的视频轨道宽高、hvcC 盒与帧数据，防止音轨或时间码轨覆盖视频样本偏移和大小。
  static (int width, int height, Uint8List hvccBox, Uint8List hevcSample)
      _extractHevcFrameFromMp4(Uint8List b) {
    int bestWidth = 0;
    int bestHeight = 0;
    Uint8List? bestHvcc;
    int bestOffset = 0;
    int bestSize = 0;

    void inspectTrak(int start, int end) {
      int tWidth = 0;
      int tHeight = 0;
      Uint8List? tHvcc;
      int tOffset = 0;
      int tSize = 0;

      void walkTrak(int s, int e) {
        int p = s;
        while (p + 8 <= e) {
          final bd = ByteData.sublistView(b, p, p + 8);
          int sz = bd.getUint32(0);
          final typ = latin1.decode(b.sublist(p + 4, p + 8));
          int hdrLen = 8;
          if (sz == 1 && p + 16 <= e) {
            sz = ByteData.sublistView(b, p + 8, p + 16).getUint64(0);
            hdrLen = 16;
          } else if (sz == 0) {
            sz = e - p;
          }
          if (sz < hdrLen || p + sz > e) break;

          if (typ == 'mdia' || typ == 'minf' || typ == 'stbl') {
            walkTrak(p + hdrLen, p + sz);
          } else if (typ == 'stsd' && p + 16 + 86 <= p + sz) {
            final ep = p + 16;
            final eBd = ByteData.sublistView(b, ep, ep + 36);
            final esz = eBd.getUint32(0);
            tWidth = eBd.getUint16(32);
            tHeight = eBd.getUint16(34);
            int sp = ep + 86;
            final eEnd = (ep + esz <= p + sz) ? ep + esz : p + sz;
            while (sp + 8 <= eEnd) {
              final ssz = ByteData.sublistView(b, sp, sp + 4).getUint32(0);
              final styp = latin1.decode(b.sublist(sp + 4, sp + 8));
              if (ssz < 8 || sp + ssz > eEnd) break;
              if (styp == 'hvcC') {
                tHvcc = b.sublist(sp, sp + ssz);
                break;
              }
              sp += ssz;
            }
          } else if (typ == 'stsz' && p + 20 <= p + sz) {
            final sBd = ByteData.sublistView(b, p + 12, p + sz);
            tSize = sBd.getUint32(0);
            if (tSize == 0 && p + 24 <= p + sz) {
              tSize = sBd.getUint32(8);
            }
          } else if (typ == 'stco' && p + 20 <= p + sz) {
            tOffset = ByteData.sublistView(b, p + 16, p + 20).getUint32(0);
          } else if (typ == 'co64' && p + 24 <= p + sz) {
            tOffset = ByteData.sublistView(b, p + 16, p + 24).getUint64(0);
          }
          p += sz;
        }
      }

      walkTrak(start, end);
      if (tHvcc != null && tSize > 0 && tOffset + tSize <= b.length) {
        bestWidth = tWidth;
        bestHeight = tHeight;
        bestHvcc = tHvcc;
        bestOffset = tOffset;
        bestSize = tSize;
      }
    }

    void walkRoot(int start, int end) {
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

        if (typ == 'moov') {
          walkRoot(p + hdrLen, p + sz);
        } else if (typ == 'trak') {
          inspectTrak(p + hdrLen, p + sz);
        }
        p += sz;
      }
    }

    walkRoot(0, b.length);
    if (bestHvcc == null || bestSize <= 1024 || bestOffset + bestSize > b.length) {
      throw StateError('无法从临时 HEVC 帧文件中提取有效的 hvcC 或图像码流 (size=$bestSize)');
    }
    return (
      bestWidth,
      bestHeight,
      bestHvcc!,
      b.sublist(bestOffset, bestOffset + bestSize),
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
      final entryHdr = ByteData(8)
        ..setUint16(0, tag, Endian.big)
        ..setUint16(2, type, Endian.big)
        ..setUint32(4, count, Endian.big);
      entries.add(entryHdr.buffer.asUint8List());
      if (rawBytes.length <= 4) {
        final val = Uint8List(4);
        val.setRange(0, rawBytes.length, rawBytes);
        entries.add(val);
      } else {
        final off = baseOffset + blobs.length;
        final offBd = ByteData(4)..setUint32(0, off, Endian.big);
        entries.add(offBd.buffer.asUint8List());
        blobs.add(rawBytes);
        if (blobs.length.isOdd) blobs.addByte(0);
      }
    }

    Uint8List asciiZero(String s) => Uint8List.fromList([...utf8.encode(s), 0]);
    Uint8List u16(int v) => (ByteData(2)..setUint16(0, v, Endian.big)).buffer.asUint8List();
    Uint8List u32(int v) => (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();
    Uint8List rational(int num, int den) => (ByteData(8)
          ..setUint32(0, num, Endian.big)
          ..setUint32(4, den, Endian.big))
        .buffer
        .asUint8List();

    final makeBytes = asciiZero(make);
    final modelBytes = asciiZero(model);
    final softBytes = asciiZero(software);

    // IFD0 按 tag 升序排列
    addEntry(ifd0Entries, blobs0, data0Offset, 0x010F, 2, makeBytes.length, makeBytes);
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0110, 2, modelBytes.length, modelBytes);
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0112, 3, 1, u16(1));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x011A, 5, 1, rational(72, 1));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x011B, 5, 1, rational(72, 1));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0128, 3, 1, u16(2));
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0131, 2, softBytes.length, softBytes);
    if (hasDate) {
      final dtBytes = asciiZero(shotStr);
      addEntry(ifd0Entries, blobs0, data0Offset, 0x0132, 2, dtBytes.length, dtBytes);
    }
    addEntry(ifd0Entries, blobs0, data0Offset, 0x0213, 3, 1, u16(1));

    final exifIfdOffsetPlaceholderIndex = ifd0Entries.length;
    addEntry(ifd0Entries, blobs0, data0Offset, 0x8769, 4, 1, u32(0));

    final exifIfdOffset = data0Offset + blobs0.length;
    final ifd0Bytes = ifd0Entries.toBytes();
    ByteData.sublistView(
      ifd0Bytes,
      exifIfdOffsetPlaceholderIndex + 8,
      exifIfdOffsetPlaceholderIndex + 12,
    ).setUint32(0, exifIfdOffset, Endian.big);

    // 构造 ExifIFD
    final hasLiveUuid = livePhotoUuid != null && livePhotoUuid.isNotEmpty;
    final hasDimensions =
        imageWidth != null && imageWidth > 0 && imageHeight != null && imageHeight > 0;
    final numExif = 3 + (hasDate ? 5 : 0) + (hasLiveUuid ? 1 : 0) + (hasDimensions ? 2 : 0);
    final dataExifOffset = exifIfdOffset + 2 + numExif * 12 + 4;

    final exifEntries = BytesBuilder();
    final blobsExif = BytesBuilder();

    addEntry(
      exifEntries,
      blobsExif,
      dataExifOffset,
      0x9000,
      7,
      4,
      Uint8List.fromList('0232'.codeUnits),
    );
    if (hasDate) {
      final dtOrig = asciiZero(shotStr);
      final dtDig = asciiZero(shotStr);
      final tzStr = _formatTimeZoneOffset(shotAt);
      final tzBytes = asciiZero(tzStr);
      addEntry(exifEntries, blobsExif, dataExifOffset, 0x9003, 2, dtOrig.length, dtOrig);
      addEntry(exifEntries, blobsExif, dataExifOffset, 0x9004, 2, dtDig.length, dtDig);
      addEntry(exifEntries, blobsExif, dataExifOffset, 0x9010, 2, tzBytes.length, tzBytes);
      addEntry(exifEntries, blobsExif, dataExifOffset, 0x9011, 2, tzBytes.length, tzBytes);
      addEntry(exifEntries, blobsExif, dataExifOffset, 0x9012, 2, tzBytes.length, tzBytes);
    }
    addEntry(
      exifEntries,
      blobsExif,
      dataExifOffset,
      0x9101,
      7,
      4,
      Uint8List.fromList([1, 2, 3, 0]),
    );
    if (hasLiveUuid) {
      final makerNote = _buildAppleMakerNote(livePhotoUuid);
      addEntry(
        exifEntries,
        blobsExif,
        dataExifOffset,
        0x927C,
        7,
        makerNote.length,
        makerNote,
      );
    }
    addEntry(exifEntries, blobsExif, dataExifOffset, 0xA001, 3, 1, u16(1));
    if (hasDimensions) {
      addEntry(exifEntries, blobsExif, dataExifOffset, 0xA002, 4, 1, u32(imageWidth));
      addEntry(exifEntries, blobsExif, dataExifOffset, 0xA003, 4, 1, u32(imageHeight));
    }

    final tiff = BytesBuilder();
    tiff.add([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]);
    tiff.add(u16(numIfd0));
    tiff.add(ifd0Bytes);
    tiff.add(u32(0));
    tiff.add(blobs0.toBytes());

    tiff.add(u16(numExif));
    tiff.add(exifEntries.toBytes());
    tiff.add(u32(0));
    tiff.add(blobsExif.toBytes());

    final tiffBytes = tiff.toBytes();
    final app1PayloadLen = 2 + 6 + tiffBytes.length;
    final app1 = BytesBuilder();
    app1.add([0xFF, 0xE1]);
    app1.add(u16(app1PayloadLen));
    app1.add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]); // "Exif\0\0"
    app1.add(tiffBytes);
    return app1.toBytes();
  }

  /// 向 JPEG 字节流注入/替换 EXIF APP1 段，并可选追加 XMP APP1 段
  static Uint8List injectJpegExifAndXmp({
    required Uint8List jpegBytes,
    required Uint8List exifApp1Segment,
    Uint8List? xmpApp1Segment,
  }) {
    if (jpegBytes.length < 4 || jpegBytes[0] != 0xFF || jpegBytes[1] != 0xD8) {
      return jpegBytes;
    }

    int pos = 2;
    while (pos + 4 <= jpegBytes.length && jpegBytes[pos] == 0xFF) {
      final marker = jpegBytes[pos + 1];
      if (marker == 0xDA || marker == 0xD9) break;
      final segLen = (jpegBytes[pos + 2] << 8) | jpegBytes[pos + 3];
      if (segLen < 2 || pos + 2 + segLen > jpegBytes.length) break;
      if (marker == 0xE0 || marker == 0xE1) {
        pos += 2 + segLen;
      } else {
        break;
      }
    }

    final out = BytesBuilder();
    out.add([0xFF, 0xD8]);
    out.add(exifApp1Segment);
    if (xmpApp1Segment != null) {
      out.add(xmpApp1Segment);
    }
    out.add(jpegBytes.sublist(pos));
    return out.toBytes();
  }

  /// 将源 MP4 转换为带完整 Apple Live Photo 元数据的 QuickTime MOV
  static Future<void> writeMovLivePhotoMetadata({
    required String srcMp4Path,
    required String outMovPath,
    required String uuid,
    required String make,
    required String model,
    DateTime? shotAt,
    double coverTimeSeconds = 1.5,
  }) async {
    final bytes = await File(srcMp4Path).readAsBytes();

    int moovOffset = -1;
    int moovSize = 0;
    int pos = 0;
    while (pos + 8 <= bytes.length) {
      final bd = ByteData.sublistView(bytes, pos, pos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(bytes.sublist(pos + 4, pos + 8));
      int hdrLen = 8;
      if (sz == 1 && pos + 16 <= bytes.length) {
        sz = ByteData.sublistView(bytes, pos + 8, pos + 16).getUint64(0);
        hdrLen = 16;
      } else if (sz == 0) {
        sz = bytes.length - pos;
      }
      if (sz < hdrLen || pos + sz > bytes.length) break;
      if (typ == 'moov') {
        moovOffset = pos;
        moovSize = sz;
        break;
      }
      pos += sz;
    }

    final qtFtyp = _wrapAtom(
      'ftyp',
      Uint8List.fromList([
        0x71, 0x74, 0x20, 0x20, // 'qt  '
        0x00, 0x00, 0x02, 0x00,
        0x71, 0x74, 0x20, 0x20, // 'qt  '
      ]),
    );

    if (moovOffset < 0) {
      await File(outMovPath).writeAsBytes(bytes);
      return;
    }

    final preMoovParts = BytesBuilder();
    int scan = 0;
    while (scan + 8 <= bytes.length) {
      final bd = ByteData.sublistView(bytes, scan, scan + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(bytes.sublist(scan + 4, scan + 8));
      int hdrLen = 8;
      if (sz == 1 && scan + 16 <= bytes.length) {
        sz = ByteData.sublistView(bytes, scan + 8, scan + 16).getUint64(0);
        hdrLen = 16;
      } else if (sz == 0) {
        sz = bytes.length - scan;
      }
      if (sz < hdrLen || scan + sz > bytes.length) break;
      if (scan == moovOffset) {
        // skip original moov
      } else if (typ == 'ftyp') {
        preMoovParts.add(qtFtyp);
      } else {
        preMoovParts.add(bytes.sublist(scan, scan + sz));
      }
      scan += sz;
    }

    final preMoovBytes = preMoovParts.toBytes();

    const stillMetaChunkPayload = <int>[
      // Sample 1: 8 bytes (0xFF before cover)
      0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
      // Sample 2: 9 bytes (0x00 at cover frame)
      0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0x00,
      // Sample 3: 8 bytes (0xFF after cover)
      0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
    ];
    final extraMdatAtom = _wrapAtom('mdat', Uint8List.fromList(stillMetaChunkPayload));
    final metaChunkFileOffset = preMoovBytes.length + 8;

    final moovBody = Uint8List.fromList(
      bytes.sublist(moovOffset + 8, moovOffset + moovSize),
    );

    final qtSec = shotAt != null
        ? (shotAt.toUtc().millisecondsSinceEpoch ~/ 1000) + _qtEpochOffset
        : null;
    if (qtSec != null && qtSec > 0) {
      _patchMoovTimestamps(moovBody, 0, moovBody.length, qtSec);
    }

    final moovInfo = _inspectMoovForStillImageTrack(moovBody);

    final cleanedMoovChildren = BytesBuilder();
    int cPos = 0;
    while (cPos + 8 <= moovBody.length) {
      final bd = ByteData.sublistView(moovBody, cPos, cPos + 8);
      int sz = bd.getUint32(0);
      final typ = latin1.decode(moovBody.sublist(cPos + 4, cPos + 8));
      if (sz == 0) sz = moovBody.length - cPos;
      if (sz < 8 || cPos + sz > moovBody.length) break;
      if (typ == 'mvhd') {
        final mvhdCopy = Uint8List.fromList(moovBody.sublist(cPos, cPos + sz));
        _bumpMvhdNextTrackId(mvhdCopy, moovInfo.newMetaTrackId + 1);
        cleanedMoovChildren.add(mvhdCopy);
      } else if (typ != 'meta' && typ != 'udta') {
        cleanedMoovChildren.add(moovBody.sublist(cPos, cPos + sz));
      }
      cPos += sz;
    }

    if (moovInfo.videoTiming != null) {
      final stillTrak = _buildStillImageTimeTrakAtom(
        metaTrackId: moovInfo.newMetaTrackId,
        videoTrackId: moovInfo.videoTiming!.trackId,
        movieTimescale: moovInfo.movieTimescale,
        movieDuration: moovInfo.movieDuration,
        videoTimescale: moovInfo.videoTiming!.videoTimescale,
        videoDuration: moovInfo.videoTiming!.videoDuration,
        frameDelta: moovInfo.videoTiming!.frameDelta,
        coverTimeSeconds: coverTimeSeconds,
        metaChunkFileOffset: metaChunkFileOffset,
        qtSec: qtSec ?? 0,
      );
      cleanedMoovChildren.add(stillTrak);
    }

    final metaAtom = _buildQtMdtaLivePhotoMetaAtom(
      uuid: uuid,
      make: make,
      model: model,
      creationDateIso: _formatIso8601WithOffset(shotAt),
    );
    cleanedMoovChildren.add(metaAtom);

    final newMoov = _wrapAtom('moov', cleanedMoovChildren.toBytes());

    final out = BytesBuilder();
    out.add(preMoovBytes);
    out.add(extraMdatAtom);
    out.add(newMoov);

    await File(outMovPath).writeAsBytes(out.toBytes());
  }

  static ({
    int movieTimescale,
    int movieDuration,
    int newMetaTrackId,
    _VideoTrackTiming? videoTiming,
  }) _inspectMoovForStillImageTrack(Uint8List moovBody) {
    int movieTimescale = 600;
    int movieDuration = 2100;
    int maxTrackId = 0;
    _VideoTrackTiming? videoTiming;

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
          movieTimescale = mBd.getUint32(20);
          movieDuration = mBd.getUint64(24);
        } else {
          movieTimescale = mBd.getUint32(12);
          movieDuration = mBd.getUint32(16);
        }
      } else if (typ == 'trak') {
        final tInfo = _parseTrakTiming(moovBody, bodyStart, bodyEnd);
        if (tInfo.trackId > maxTrackId) {
          maxTrackId = tInfo.trackId;
        }
        if (tInfo.isVideo && videoTiming == null && tInfo.videoTimescale > 0) {
          videoTiming = _VideoTrackTiming(
            trackId: tInfo.trackId,
            videoTimescale: tInfo.videoTimescale,
            videoDuration: tInfo.videoDuration,
            frameDelta: tInfo.frameDelta > 0 ? tInfo.frameDelta : 1,
          );
        }
      }
      pos += sz;
    }

    return (
      movieTimescale: movieTimescale > 0 ? movieTimescale : 600,
      movieDuration: movieDuration > 0 ? movieDuration : 2100,
      newMetaTrackId: maxTrackId + 1,
      videoTiming: videoTiming,
    );
  }

  static ({
    int trackId,
    bool isVideo,
    int videoTimescale,
    int videoDuration,
    int frameDelta,
  }) _parseTrakTiming(Uint8List buf, int start, int end) {
    int trackId = 0;
    bool isVideo = false;
    int videoTimescale = 0;
    int videoDuration = 0;
    int frameDelta = 0;

    void walk(int s, int e) {
      int p = s;
      while (p + 8 <= e) {
        final bd = ByteData.sublistView(buf, p, p + 8);
        int sz = bd.getUint32(0);
        final typ = latin1.decode(buf.sublist(p + 4, p + 8));
        if (sz == 0) sz = e - p;
        if (sz < 8 || p + sz > e) break;

        final bs = p + 8;
        final be = p + sz;

        if (typ == 'tkhd' && be - bs >= 20) {
          final ver = buf[bs];
          final tBd = ByteData.sublistView(buf, bs, be);
          trackId = ver == 1 && be - bs >= 24 ? tBd.getUint32(20) : tBd.getUint32(12);
        } else if (typ == 'mdhd' && be - bs >= 20) {
          final ver = buf[bs];
          final mBd = ByteData.sublistView(buf, bs, be);
          if (ver == 1 && be - bs >= 32) {
            videoTimescale = mBd.getUint32(20);
            videoDuration = mBd.getUint64(24);
          } else {
            videoTimescale = mBd.getUint32(12);
            videoDuration = mBd.getUint32(16);
          }
        } else if (typ == 'hdlr' && be - bs >= 12) {
          final subType = latin1.decode(buf.sublist(bs + 8, bs + 12));
          if (subType == 'vide') isVideo = true;
        } else if (typ == 'stts' && be - bs >= 16) {
          final sBd = ByteData.sublistView(buf, bs, be);
          final entryCount = sBd.getUint32(4);
          if (entryCount >= 1) {
            frameDelta = sBd.getUint32(12);
          }
        } else if (typ == 'mdia' || typ == 'minf' || typ == 'stbl') {
          walk(bs, be);
        }
        p += sz;
      }
    }

    walk(start, end);
    return (
      trackId: trackId,
      isVideo: isVideo,
      videoTimescale: videoTimescale,
      videoDuration: videoDuration,
      frameDelta: frameDelta,
    );
  }

  static void _bumpMvhdNextTrackId(Uint8List mvhdAtom, int nextTrackId) {
    if (mvhdAtom.length < 16) return;
    final ver = mvhdAtom[8];
    final nextIdOffset = ver == 1 ? 8 + 104 : 8 + 92;
    if (nextIdOffset + 4 <= mvhdAtom.length) {
      ByteData.sublistView(
        mvhdAtom,
        nextIdOffset,
        nextIdOffset + 4,
      ).setUint32(0, nextTrackId, Endian.big);
    }
  }

  static Uint8List _buildStillImageTimeTrakAtom({
    required int metaTrackId,
    required int videoTrackId,
    required int movieTimescale,
    required int movieDuration,
    required int videoTimescale,
    required int videoDuration,
    required int frameDelta,
    required double coverTimeSeconds,
    required int metaChunkFileOffset,
    required int qtSec,
  }) {
    final oneFrameTicks = frameDelta > 0 ? frameDelta : (videoTimescale ~/ 30);
    int coverTicks = (coverTimeSeconds * videoTimescale).round();
    if (oneFrameTicks > 0) {
      coverTicks = (coverTicks ~/ oneFrameTicks) * oneFrameTicks;
    }
    if (coverTicks <= 0 || coverTicks + oneFrameTicks >= videoDuration) {
      coverTicks = (videoDuration ~/ 2);
      if (oneFrameTicks > 0) {
        coverTicks = (coverTicks ~/ oneFrameTicks) * oneFrameTicks;
      }
    }
    if (coverTicks < oneFrameTicks) {
      coverTicks = oneFrameTicks;
    }
    final tailTicks = videoDuration > (coverTicks + oneFrameTicks)
        ? videoDuration - coverTicks - oneFrameTicks
        : oneFrameTicks;
    final totalVideoTicks = coverTicks + oneFrameTicks + tailTicks;

    final tkhdPayload = ByteData(84)
      ..setUint32(0, 0x0000000F, Endian.big)
      ..setUint32(4, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(8, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(12, metaTrackId, Endian.big)
      ..setUint32(16, 0, Endian.big)
      ..setUint32(20, movieDuration, Endian.big)
      ..setUint32(40, 0x00010000, Endian.big)
      ..setUint32(56, 0x00010000, Endian.big)
      ..setUint32(72, 0x40000000, Endian.big);
    final tkhdAtom = _wrapAtom('tkhd', tkhdPayload.buffer.asUint8List());

    final cdscPayload = ByteData(4)..setUint32(0, videoTrackId, Endian.big);
    final trefAtom = _wrapAtom('tref', _wrapAtom('cdsc', cdscPayload.buffer.asUint8List()));

    final elstPayload = ByteData(20)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, 1, Endian.big)
      ..setUint32(8, movieDuration, Endian.big)
      ..setInt32(12, 0, Endian.big)
      ..setUint32(16, 0x00010000, Endian.big);
    final edtsAtom = _wrapAtom('edts', _wrapAtom('elst', elstPayload.buffer.asUint8List()));

    final mdhdPayload = ByteData(24)
      ..setUint32(0, 0, Endian.big)
      ..setUint32(4, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(8, qtSec & 0xFFFFFFFF, Endian.big)
      ..setUint32(12, videoTimescale, Endian.big)
      ..setUint32(16, totalVideoTicks, Endian.big)
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
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x19,
        ...'Core Media Metadata Track'.codeUnits,
      ]),
    );

    final gmhdAtom = _wrapAtom(
      'gmhd',
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18,
        0x67, 0x6D, 0x69, 0x6E,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x40,
        0x80, 0x00, 0x80, 0x00,
        0x80, 0x00,
        0x00, 0x00,
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

    final uuidBytes = Uint8List.fromList([...utf8.encode(uuid), 0]);

    addMnEntry(0x0001, 9, 1, s32(14));
    addMnEntry(0x0003, 7, runTimeBplist.length, Uint8List.fromList(runTimeBplist));
    addMnEntry(0x0008, 10, 3, accelBytes.buffer.asUint8List());
    addMnEntry(0x0011, 2, uuidBytes.length, uuidBytes);
    addMnEntry(0x0014, 9, 1, s32(10));
    addMnEntry(0x0017, 10, 1, (ByteData(8)..setInt32(0, 900, Endian.big)..setInt32(4, 1, Endian.big)).buffer.asUint8List());

    final out = BytesBuilder();
    out.add('Apple iOS\x00'.codeUnits);
    out.add([0x00, 0x01, 0x4D, 0x4D]);
    out.add((ByteData(2)..setUint16(0, numEntries, Endian.big)).buffer.asUint8List());
    out.add(entries.toBytes());
    out.add([0x00, 0x00, 0x00, 0x00]);
    out.add(blobs.toBytes());
    return out.toBytes();
  }

  static String? _formatExifDate(DateTime? dt) {
    if (dt == null) return null;
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}:${p2(dt.month)}:${p2(dt.day)} ${p2(dt.hour)}:${p2(dt.minute)}:${p2(dt.second)}';
  }

  static String _formatTimeZoneOffset(DateTime? dt) {
    final off = (dt ?? DateTime.now()).timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final totalMin = off.inMinutes.abs();
    final h = (totalMin ~/ 60).toString().padLeft(2, '0');
    final m = (totalMin % 60).toString().padLeft(2, '0');
    return '$sign$h:$m';
  }

  static String? _formatIso8601WithOffset(DateTime? dt) {
    if (dt == null) return null;
    String p2(int n) => n.toString().padLeft(2, '0');
    final tz = _formatTimeZoneOffset(dt);
    return '${dt.year}-${p2(dt.month)}-${p2(dt.day)}T${p2(dt.hour)}:${p2(dt.minute)}:${p2(dt.second)}$tz';
  }
}
