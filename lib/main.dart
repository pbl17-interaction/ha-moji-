import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 横向き固定
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

  // —— レイアウトパラメータ ——
  static const double _marginFactor = 1.0;                 //正方形の大きさ
  static const double _borderRadius = 12.0;
  static const double _borderWidth = 9.0;
  static const double _penWidth = 6.0;

  // —— 録音・再生 ——
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _audioPath;
  bool _isRecording = false;

  String _fmt(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('まだ何も書かれていません')),
      );
      return;
    }
    try {
      await _stopRecordingIfNeeded();
      await Future.delayed(const Duration(milliseconds: 16));

      final boundary = _repaintKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      if (_audioPath != null) {
        await _player.stop();
        await _player.setSource(DeviceFileSource(_audioPath!));
        await _player.setReleaseMode(ReleaseMode.stop);
      }

      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (_) => _PreviewDialog(
          audioPath: _audioPath,
          imageBytes: bytes,
          player: _player,
          fmt: _fmt,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラー: $e')),
      );
    }
  }

  bool _isInside(Offset p, Size s) {
    final rect = Rect.fromLTWH(0, 0, s.width, s.height).deflate(_borderWidth);
    return rect.contains(p);
  }

  Future<void> _startRecordingIfNeeded() async {
    if (_isRecording) return;
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) return;

    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/recordings');
    if (!await recDir.exists()) {
      await recDir.create(recursive: true);
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    _audioPath = '${recDir.path}/note_$ts.m4a';

    const cfg = RecordConfig(encoder: AudioEncoder.aacLc);
    await _recorder.start(cfg, path: _audioPath!);
    _isRecording = true;
  }

  Future<void> _stopRecordingIfNeeded() async {
    if (!_isRecording) return;
    try {
      await _recorder.stop();
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
    const double topSpace = 80.0; 
    const double gap = 5.0;//文字と四角の距離

    // 【変更点1】Scaffoldで包み、下線トラブルを回避
    return Scaffold(
      backgroundColor: const Color(0xFF2B2B2B),
      body: SafeArea(
        child: Stack(
          children: [
            // 1. メインコンテンツ
            Column(
              children: [
                const SizedBox(height: topSpace),
                
                const _HintText('Enter text.'),
                const SizedBox(height: gap),

                // 正方形の描画エリア
                Expanded(
                  child: Center(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final double side = math.min(constraints.maxWidth, constraints.maxHeight) * _marginFactor;

                        return SizedBox(
                          width: side,
                          height: side,
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
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(_borderRadius),
                                child: Stack(
                                  children: [
                                    Positioned.fill(
                                      child: CustomPaint(painter: _GridPainter()),
                                    ),
                                    LayoutBuilder(
                                      builder: (context, c) {
                                        final Size paintSize = Size(c.maxWidth, c.maxHeight);
                                        return GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onPanStart: (d) {
                                            if (_isInside(d.localPosition, paintSize)) {
                                              _startRecordingIfNeeded();
                                              setState(() {
                                                _current = _Stroke()..points.add(d.localPosition);
                                                _strokes.add(_current!);
                                              });
                                            }
                                          },
                                          onPanUpdate: (d) {
                                            if (_isInside(d.localPosition, paintSize)) {
                                              setState(() => _current?.points.add(d.localPosition));
                                            }
                                          },
                                          onPanEnd: (_) => _current = null,
                                          child: CustomPaint(
                                            painter: _CanvasPainter(_strokes, penWidth: _penWidth),
                                            size: paintSize,
                                          ),
                                        );
                                      },
                                    ),
                                  ],
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
                const SizedBox(height: 40), 
              ],
            ),

            // 2. 左上のClearボタン
            Positioned(
              top: 16,
              left: 38,
              child: OutlinedButton(
                onPressed: _clear,
                style: OutlinedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(38),                  //ボタンの大きさ
                  side: BorderSide.none, // 線をなしにする
                  foregroundColor: Colors.white,
                ),
                child: const Icon(Icons.refresh, size: 68),
              ),
            ),

            // 3. 右上のDoneボタン
            Positioned(
              top: 16,
              right: 38,
              child: OutlinedButton(
                onPressed: _confirm,
                style: OutlinedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: const EdgeInsets.all(38),
                  side: BorderSide.none,
                  //backgroundColor: Colors.white,
                  foregroundColor: Colors.white,
                  //elevation: 4,
                ),
                child: Transform.translate(
                  offset: const Offset(0, -10),
                  
                child: Image.asset(
                  'assets/icon_push.png',
                  width: 68,
                  height: 68,
                  fit: BoxFit.contain,
                  ),
              ),
            ),
            ),
          ],
        ),
      ),
    );
  }
}

// ——— クラス定義 ———

class _HintText extends StatelessWidget {
  const _HintText(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white, 
        fontSize: 30,                                   //文字の大きさ
        // 【変更点2】明示的に装飾なし（下線なし）を指定
        //letterSpacing: 2.0,
        decoration: TextDecoration.none,
      ),
      textAlign: TextAlign.center,
    );
  }
}

// 十字ガイドラインを描くクラス
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;

    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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

// ——— プレビューダイアログ ———
class _PreviewDialog extends StatefulWidget {
  final String? audioPath;
  final Uint8List imageBytes;
  final AudioPlayer player;
  final String Function(Duration) fmt;

  const _PreviewDialog({
    required this.audioPath,
    required this.imageBytes,
    required this.player,
    required this.fmt,
  });

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2B2B),
      contentPadding: const EdgeInsets.all(16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.audioPath != null) ...[
             StreamBuilder<PlayerState>(
               stream: widget.player.onPlayerStateChanged,
               builder: (ctx, snap) {
                 final state = snap.data ?? PlayerState.stopped;
                 return IconButton(
                   icon: Icon(state == PlayerState.playing ? Icons.pause : Icons.play_arrow),
                   color: Colors.white,
                   onPressed: () => state == PlayerState.playing 
                       ? widget.player.pause() 
                       : widget.player.resume(),
                 );
               },
             ),
             const SizedBox(height: 8),
          ],
          Image.memory(widget.imageBytes, width: 300, height: 300),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.player.stop();
            Navigator.pop(context);
          },
          child: const Text('Close'),
        ),
      ],
    );
  }
}