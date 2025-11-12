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

  // 時間表示フォーマット
  String _fmt(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hh = d.inHours;
    return hh > 0 ? '$hh:$mm:$ss' : '$mm:$ss';
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('まだ何も書かれていません')));
      return;
    }
    try {
      // 先に録音停止
      await _stopRecordingIfNeeded();

      // RepaintBoundary の描画完了を待つ保険
      await Future.delayed(const Duration(milliseconds: 16));

      final boundary =
          _repaintKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      // 音声ソースをセット（ある場合）
      if (_audioPath != null) {
        await _player.stop();
        await _player.setSource(DeviceFileSource(_audioPath!));
        await _player.setReleaseMode(ReleaseMode.stop);
      }

      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (ctx, setStateDialog) {
            Future<void> _togglePlay(PlayerState state) async {
              if (_audioPath == null) return;
              if (state == PlayerState.playing) {
                await _player.pause();
              } else {
                await _player.resume(); // Source は事前に setSource 済み
              }
            }

            final screenH = MediaQuery.of(ctx).size.height;
            final maxDialogH = screenH * 0.8; // ダイアログの最大高さ

            return AlertDialog(
              backgroundColor: const Color(0xFF2B2B2B),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              title: const Text('プレビュー'),
              content: SizedBox(
                // ★ListViewに確実な高さを与える（これがないと unbounded になりがち）
                height: maxDialogH,
                width: 720, // 任意の横幅上限（調整/削除可）
                child: ListView(
                  padding: EdgeInsets.zero,
                  // ↓↓↓ 重要ポイント（安定化） ↓↓↓
                  shrinkWrap: true,
                  primary: false,
                  children: [
                    if (_audioPath != null) ...[
                      // ===== 再生UI（先頭アイテム） =====
                      StreamBuilder<PlayerState>(
                        stream: _player.onPlayerStateChanged,
                        initialData: PlayerState.stopped,
                        builder: (context, stateSnap) {
                          final state = stateSnap.data ?? PlayerState.stopped;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            // 内側は Column（ネスト ListView 禁止）
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    IconButton(
                                      onPressed: () => _togglePlay(state),
                                      icon: Icon(
                                        state == PlayerState.playing
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                      ),
                                      tooltip: state == PlayerState.playing
                                          ? '一時停止'
                                          : '再生',
                                    ),
                                    Expanded(
                                      child: StreamBuilder<Duration>(
                                        stream: _player.onPositionChanged,
                                        initialData: Duration.zero,
                                        builder: (context, posSnap) {
                                          final pos =
                                              posSnap.data ?? Duration.zero;
                                          return StreamBuilder<Duration?>(
                                            stream: _player.onDurationChanged,
                                            initialData: Duration.zero,
                                            builder: (context, durSnap) {
                                              final dur =
                                                  durSnap.data ?? Duration.zero;
                                              final maxMs =
                                                  dur.inMilliseconds <= 0
                                                  ? 1
                                                  : dur.inMilliseconds;
                                              final valMs = pos.inMilliseconds
                                                  .clamp(0, maxMs);

                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  Slider(
                                                    value: valMs.toDouble(),
                                                    min: 0,
                                                    max: maxMs.toDouble(),
                                                    onChanged:
                                                        (
                                                          double newValue,
                                                        ) async {
                                                          if (dur ==
                                                              Duration.zero)
                                                            return;
                                                          final seekTo =
                                                              Duration(
                                                                milliseconds:
                                                                    newValue
                                                                        .toInt(),
                                                              );
                                                          await _player.seek(
                                                            seekTo,
                                                          );
                                                        },
                                                  ),
                                                  Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      Text(_fmt(pos)),
                                                      Text(_fmt(dur)),
                                                    ],
                                                  ),
                                                ],
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],

                    // ===== 画像（2個目のアイテム） =====
                    // 画像が大きくても ListView 内なので必ずスクロール可能
                    Image.memory(bytes, fit: BoxFit.contain),
                  ],
                ),
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
