import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

void main() {
  // 全屏沉浸模式
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // 锁定竖屏，任何时候不旋转
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zmedia',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const ZmediaScreen(),
    );
  }
}

/// 一个媒体条目：要么是图片，要么是视频
class MediaItem {
  final File file;
  final bool isVideo;
  MediaItem(this.file, this.isVideo);
}

class ZmediaScreen extends StatefulWidget {
  const ZmediaScreen({super.key});

  @override
  State<ZmediaScreen> createState() => _ZmediaScreenState();
}

class _ZmediaScreenState extends State<ZmediaScreen> {
  static const String _mediaDir = '/sdcard/Pictures/WeiXin';

  // 初始页设成一个很大的值，保证往两个方向都能无限滑
  static const int _initialPage = 1000000;

  final PageController _pageController = PageController(
    initialPage: _initialPage,
  );
  List<MediaItem> _items = [];
  int _currentIndex = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final granted = await _ensureStoragePermission();
    if (!granted) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '未获得存储权限，请到系统设置中为「zimage」开启「所有文件访问权」';
        });
      }
      return;
    }

    final items = _scanZmedia();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
        _error = items.isEmpty ? 'Zmedia 文件夹为空' : null;
        // 初始页对应的实际索引
        if (items.isNotEmpty) {
          _currentIndex = _initialPage % items.length;
        }
      });
    }
  }

  /// 检查/申请「所有文件访问权」
  Future<bool> _ensureStoragePermission() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (await Permission.storage.isGranted) return true;

    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied || status.isDenied) {
      await openAppSettings();
      return await Permission.manageExternalStorage.isGranted ||
          await Permission.storage.isGranted;
    }
    return false;
  }

  /// 扫描 /sdcard/Zmedia
  List<MediaItem> _scanZmedia() {
    final dir = Directory(_mediaDir);
    if (!dir.existsSync()) return [];

    const videoExts = {'.mp4', '.mkv', '.avi', '.mov', '.webm', '.3gp', '.flv'};
    const imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};

    final result = <MediaItem>[];
    try {
      for (final entity in dir.listSync(recursive: false)) {
        if (entity is! File) continue;
        final path = entity.path.toLowerCase();
        if (videoExts.any(path.endsWith)) {
          result.add(MediaItem(entity, true));
        } else if (imageExts.any(path.endsWith)) {
          result.add(MediaItem(entity, false));
        }
      }
    } catch (_) {
      return [];
    }
    result.sort((a, b) => a.file.path.compareTo(b.file.path));
    return result;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white70)),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // 只有一个媒体时不循环，避免反复重建同一个 VideoPage
    final bool looping = _items.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        // 多个媒体时无限循环；只有一个时限定数量
        itemCount: looping ? null : 1,
        onPageChanged: (i) {
          if (_items.isEmpty) return;
          // 用 ((i % len) + len) % len 保证负数也能正确映射
          final len = _items.length;
          setState(() => _currentIndex = ((i % len) + len) % len);
        },
        itemBuilder: (context, index) {
          final len = _items.length;
          final realIndex = ((index % len) + len) % len;
          final item = _items[realIndex];
          if (item.isVideo) {
            return VideoPage(
              key: ValueKey(item.file.path),
              file: item.file,
              isActive: realIndex == _currentIndex,
            );
          }
          return ImagePage(file: item.file);
        },
      ),
    );
  }
}

/// 图片页：保持比例、完整显示
class ImagePage extends StatelessWidget {
  final File file;
  const ImagePage({super.key, required this.file});

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Center(
          child: Icon(Icons.broken_image, color: Colors.white24, size: 64),
        ),
      ),
    );
  }
}

/// 视频页：循环播放，只有当前页才播放，完整显示不裁剪
class VideoPage extends StatefulWidget {
  final File file;
  final bool isActive;
  const VideoPage({super.key, required this.file, required this.isActive});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file);
    _controller.setLooping(true); // 循环播放
    _controller.setVolume(1.0);
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _initialized = true);
          // 初始化完成时如果它是当前页，立即播放
          if (widget.isActive) {
            _controller.play();
          }
        })
        .catchError((e) {
          if (!mounted) return;
          setState(() => _initialized = false);
        });
  }

  @override
  void didUpdateWidget(covariant VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        // 滑入当前页：从头开始播放
        _controller.seekTo(Duration.zero);
        _controller.play();
      } else {
        // 滑走：暂停并归零
        _controller.pause();
        _controller.seekTo(Duration.zero);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    // BoxFit.contain：横屏视频按宽度自适应，完整显示，不裁剪
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: _controller.value.size.width,
          height: _controller.value.size.height,
          child: VideoPlayer(_controller),
        ),
      ),
    );
  }
}
