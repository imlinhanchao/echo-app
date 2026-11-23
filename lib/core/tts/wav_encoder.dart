import 'dart:typed_data';

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
