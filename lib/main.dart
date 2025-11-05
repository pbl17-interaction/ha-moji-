import 'dart:math' as math; // 高さクリップ用
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart'; // record ^6.1.2
import 'package:audioplayers/audioplayers.dart'; // audioplayers ^6.5.1

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 横向き固定（不要なら削除OK）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Draw Text',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF2B2B2B),
      ),
      home: const DrawPage(),
    );
  }
}

class DrawPage extends StatefulWidget {
  const DrawPage({super.key});

  @override
  State<DrawPage> createState() => _DrawPageState();
}

class _DrawPageState extends State<DrawPage> {
  final List<_Stroke> _strokes = [];
  _Stroke? _current;
  final GlobalKey _repaintKey = GlobalKey();

  // —— レイアウト／見た目パラメータ ——
  static const double _widthFactor = 0.8; // 画面（親幅）の80%を横幅に
  static const double _borderRadius = 12.0;
  static const double _borderWidth = 6.0;
  static const double _penWidth = 6.0;

  // —— 録音・再生 —— (record 6.x / audioplayers 6.x)
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _audioPath;
  bool _isRecording = false;

  void _clear() {
    setState(() {
      _strokes.clear();
      _current = null;
    });
    _stopRecordingIfNeeded();
    _audioPath = null;
  }

  Future<void> _confirm() async {
    if (_strokes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('まだ何も書かれていません')));
      return;
    }
    try {
      // 録音停止（重複停止は無害）
      await _stopRecordingIfNeeded();

      // RepaintBoundary の描画完了を待つ保険（必要に応じて）
      await Future.delayed(const Duration(milliseconds: 16));

      final boundary =
          _repaintKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      if (!mounted) return;

      bool isPlaying = false;

      await showDialog(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (ctx, setStateDialog) {
            Future<void> _togglePlay() async {
              if (_audioPath == null) return;
              if (!isPlaying) {
                await _player.stop();
                await _player.play(DeviceFileSource(_audioPath!));
                isPlaying = true;
              } else {
                await _player.stop();
                isPlaying = false;
              }
              setStateDialog(() {});
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF2B2B2B),
              title: const Text('プレビュー'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.memory(bytes),
                  const SizedBox(height: 12),
                  if (_audioPath != null) ...[
                    SelectableText(
                      '音声ファイル: $_audioPath',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _togglePlay,
                      icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
                      label: Text(isPlaying ? '停止' : '再生'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _player.stop();
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('閉じる'),
                ),
              ],
            );
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エクスポートに失敗しました: $e')));
    }
  }

  // —— 枠内ヒット判定（枠線の太さ分だけ内側を有効領域に）——
  bool _isInside(Offset p, Size s) {
    final rect = Rect.fromLTWH(0, 0, s.width, s.height).deflate(_borderWidth);
    return rect.contains(p);
  }

  // —— 録音制御（record 6.x API）——
  Future<void> _startRecordingIfNeeded() async {
    if (_isRecording) return;

    final hasPerm = await _recorder.hasPermission(); // 権限確認（要求まで兼ねる）
    if (!hasPerm) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('マイク権限がありません')));
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/recordings');
    if (!await recDir.exists()) {
      await recDir.create(recursive: true);
    }
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '');
    _audioPath = '${recDir.path}/note_$ts.m4a';

    final cfg = RecordConfig(
      encoder: AudioEncoder.aacLc,
      bitRate: 128000,
      sampleRate: 44100,
      numChannels: 1,
      noiseSuppress: false,
      echoCancel: false,
      autoGain: false,
    );

    await _recorder.start(cfg, path: _audioPath!);
    _isRecording = true;
  }

  Future<void> _stopRecordingIfNeeded() async {
    if (!_isRecording) return;
    try {
      await _recorder.stop(); // 返り値は保存パスだが _audioPath を使用する
    } finally {
      _isRecording = false;
    }
  }

  @override
  void dispose() {
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const hPad = 24.0;
    const gap = 16.0;

    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: gap),
          const _HintText('Enter text.'),
          const SizedBox(height: gap),

          // —— 書きエリア（横%指定＋縦は16:9、Expandedで縦を有限に）——
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: hPad),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 横幅＝親幅×割合
                  final double w = constraints.maxWidth * _widthFactor;
                  // 16:9の理想高さ
                  final double desiredH = w * 9 / 16;
                  // 利用可能な高さにクリップ（常に有限）
                  final double h = math.min(desiredH, constraints.maxHeight);

                  return Center(
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: RepaintBoundary(
                        key: _repaintKey,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2B2B2B),
                            borderRadius: BorderRadius.circular(_borderRadius),
                            border: Border.all(
                              color: Colors.white,
                              width: _borderWidth,
                            ),
                          ),
                          // —— ① 視覚的クリップ（角丸で内側だけ描画）——
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(_borderRadius),
                            child: LayoutBuilder(
                              builder: (context, c) {
                                final Size paintSize = Size(
                                  c.maxWidth,
                                  c.maxHeight,
                                );

                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  // —— ② 枠外を無視（外なら開始しない／外に出たら中断）——
                                  onPanStart: (d) {
                                    if (_isInside(d.localPosition, paintSize)) {
                                      // 追加：ストローク開始時に録音を起動
                                      _startRecordingIfNeeded();

                                      setState(() {
                                        _current = _Stroke()
                                          ..points.add(d.localPosition);
                                        _strokes.add(_current!);
                                      });
                                    } else {
                                      _current = null;
                                    }
                                  },
                                  onPanUpdate: (d) {
                                    if (_isInside(d.localPosition, paintSize)) {
                                      setState(
                                        () => _current?.points.add(
                                          d.localPosition,
                                        ),
                                      );
                                    } else {
                                      _current = null; // 外に出たらストローク終了
                                    }
                                  },
                                  onPanEnd: (_) => _current = null,
                                  child: CustomPaint(
                                    painter: _CanvasPainter(
                                      _strokes,
                                      penWidth: _penWidth,
                                    ),
                                    size: paintSize,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(height: gap),
          const _HintText('Enter text.'),

          // 下部ボタン
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: hPad, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _clear,
                    icon: const Icon(Icons.refresh),
                    label: const Text('もう一度書く'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white, width: 2),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _confirm,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('決定'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HintText extends StatelessWidget {
  const _HintText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _Stroke {
  final List<Offset> points = [];
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter(this.strokes, {this.penWidth = 6});
  final List<_Stroke> strokes;
  final double penWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = penWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final s in strokes) {
      for (int i = 0; i < s.points.length - 1; i++) {
        canvas.drawLine(s.points[i], s.points[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.penWidth != penWidth;
}
