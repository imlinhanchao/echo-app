import 'dart:math' as math;
import 'dart:typed_data';

/// WAV 解码结果（归一化到 `[-1.0, 1.0]` 单声道 Float32 采样）。
class DecodedWavAudio {
  const DecodedWavAudio({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  final Float32List samples;
  final int sampleRate;
  final int channels;
}

/// 解析标准及扩展 RIFF WAVE 文件（正确跳过 `LIST` / `JUNK` / `fact` 等非数据块），
/// 支持 8/16/24-bit PCM 与 32-bit IEEE Float，多声道自动混音为单声道。
DecodedWavAudio decodeWavToFloat32(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const FormatException('WAV 文件过小，缺少 RIFF 头');
  }
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final wave = String.fromCharCodes(bytes.sublist(8, 12));
  if (riff != 'RIFF' || wave != 'WAVE') {
    throw const FormatException('仅支持标准 RIFF WAVE（.wav）音频文件');
  }

  final bd = ByteData.sublistView(bytes);
  var audioFormat = 0;
  var channels = 0;
  var sampleRate = 0;
  var bitsPerSample = 0;
  var dataOffset = -1;
  var dataSize = 0;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = bd.getUint32(offset + 4, Endian.little);
    final payloadStart = offset + 8;
    final payloadEnd = math.min(bytes.length, payloadStart + chunkSize);

    if (chunkId == 'fmt ' && payloadEnd - payloadStart >= 16) {
      audioFormat = bd.getUint16(payloadStart, Endian.little);
      channels = bd.getUint16(payloadStart + 2, Endian.little);
      sampleRate = bd.getUint32(payloadStart + 4, Endian.little);
      bitsPerSample = bd.getUint16(payloadStart + 14, Endian.little);
      if (audioFormat == 0xFFFE && payloadEnd - payloadStart >= 26) {
        audioFormat = bd.getUint16(payloadStart + 24, Endian.little);
      }
    } else if (chunkId == 'data') {
      dataOffset = payloadStart;
      dataSize = payloadEnd - payloadStart;
      break;
    }

    final paddedSize = chunkSize + (chunkSize.isOdd ? 1 : 0);
    final nextOffset = payloadStart + paddedSize;
    if (nextOffset <= offset) break;
    offset = nextOffset;
  }

  if (dataOffset < 0 || sampleRate <= 0 || channels <= 0) {
    throw const FormatException('WAV 文件缺少有效的 fmt / data 块');
  }

  final isPcm = audioFormat == 1 && (bitsPerSample == 8 || bitsPerSample == 16 || bitsPerSample == 24);
  final isFloat32 = audioFormat == 3 && bitsPerSample == 32;
  if (!isPcm && !isFloat32) {
    throw FormatException('暂不支持的 WAV 编码（format=$audioFormat, bits=$bitsPerSample）');
  }

  final bytesPerSample = bitsPerSample ~/ 8;
  final blockAlign = channels * bytesPerSample;
  if (blockAlign <= 0) {
    throw const FormatException('WAV 块对齐参数无效');
  }
  final frameCount = dataSize ~/ blockAlign;
  final mono = Float32List(frameCount);

  for (var f = 0; f < frameCount; f++) {
    var sum = 0.0;
    final frameBase = dataOffset + f * blockAlign;
    for (var ch = 0; ch < channels; ch++) {
      final pos = frameBase + ch * bytesPerSample;
      final double v;
      if (isFloat32) {
        v = bd.getFloat32(pos, Endian.little);
      } else if (bitsPerSample == 16) {
        v = bd.getInt16(pos, Endian.little) / 32768.0;
      } else if (bitsPerSample == 24) {
        var raw = bytes[pos] | (bytes[pos + 1] << 8) | (bytes[pos + 2] << 16);
        if ((raw & 0x800000) != 0) raw -= 0x1000000;
        v = raw / 8388608.0;
      } else {
        v = (bytes[pos] - 128) / 128.0;
      }
      sum += v;
    }
    mono[f] = (sum / channels).clamp(-1.0, 1.0);
  }

  return DecodedWavAudio(
    samples: mono,
    sampleRate: sampleRate,
    channels: channels,
  );
}

/// 将 Float32 [-1.0, 1.0] 单声道音频采样编码为 16-bit PCM 字节。
Uint8List float32ToPcm16(Float32List samples) {
  final byteData = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    final intVal = (clamped * 32767.0).round().clamp(-32768, 32767);
    byteData.setInt16(i * 2, intVal, Endian.little);
  }
  return byteData.buffer.asUint8List();
}

/// 将 Float32 单声道音频采样编码为标准 16-bit PCM WAV 字节（含 44 字节 RIFF 头）。
Uint8List encodeFloat32ToWav(
  Float32List samples, {
  required int sampleRate,
  int numChannels = 1,
}) {
  final pcm = float32ToPcm16(samples);
  return wrapPcm16AsWav(pcm, sampleRate: sampleRate, numChannels: numChannels);
}

/// 为 16-bit PCM 原始字节加上标准 44 字节 WAV RIFF 文件头。
Uint8List wrapPcm16AsWav(
  Uint8List pcmBytes, {
  required int sampleRate,
  int numChannels = 1,
}) {
  const bitsPerSample = 16;
  final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
  final blockAlign = numChannels * (bitsPerSample ~/ 8);
  final dataSize = pcmBytes.length;
  final fileSize = 36 + dataSize;

  final header = ByteData(44);
  // "RIFF"
  header.setUint8(0, 0x52);
  header.setUint8(1, 0x49);
  header.setUint8(2, 0x46);
  header.setUint8(3, 0x46);
  header.setUint32(4, fileSize, Endian.little);
  // "WAVE"
  header.setUint8(8, 0x57);
  header.setUint8(9, 0x41);
  header.setUint8(10, 0x56);
  header.setUint8(11, 0x45);
  // "fmt "
  header.setUint8(12, 0x66);
  header.setUint8(13, 0x6D);
  header.setUint8(14, 0x74);
  header.setUint8(15, 0x20);
  header.setUint32(16, 16, Endian.little); // PCM chunk size
  header.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
  header.setUint16(22, numChannels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  // "data"
  header.setUint8(36, 0x64);
  header.setUint8(37, 0x61);
  header.setUint8(38, 0x74);
  header.setUint8(39, 0x61);
  header.setUint32(40, dataSize, Endian.little);

  final out = Uint8List(44 + dataSize);
  out.setRange(0, 44, header.buffer.asUint8List());
  out.setRange(44, 44 + dataSize, pcmBytes);
  return out;
}
