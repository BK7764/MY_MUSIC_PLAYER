import 'dart:async';
import 'dart:convert';

import 'dart:io';




import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:just_audio/just_audio.dart';

import 'package:just_audio_background/just_audio_background.dart';

import 'package:permission_handler/permission_handler.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:video_player/video_player.dart';



Future<void> main() async {

  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'my_music_player.audio',
    androidNotificationChannelName: 'Music Playback',
    androidNotificationChannelDescription:
        'Music playback controls, song information and artwork',
    // Keep the media notification available while music is playing and while
    // the app is in the background/screen is off.
    androidNotificationOngoing: true,
    androidNotificationClickStartsActivity: true,
    androidNotificationIcon: 'drawable/ic_music_notification',
    androidShowNotificationBadge: true,
    // Do not remove the foreground media notification just because playback
    // is paused. The user can resume directly from the notification/lock screen.
    androidStopForegroundOnPause: false,
    // Keep artwork small enough for fast notification updates.
    artDownscaleWidth: 512,
    artDownscaleHeight: 512,
    preloadArtwork: true,
  );

  runApp(const MyMusicPlayer());

}



class MyMusicPlayer extends StatelessWidget {

  const MyMusicPlayer({super.key});

  @override

  Widget build(BuildContext context) {

    return MaterialApp(

      debugShowCheckedModeBanner: false,

      title: 'My Music Player',

      theme: ThemeData(

        brightness: Brightness.dark,

        scaffoldBackgroundColor: Colors.black,

        colorScheme: ColorScheme.fromSeed(

          seedColor: Colors.deepOrange,

          brightness: Brightness.dark,

        ),

        useMaterial3: true,

      ),

      home: const MusicHomePage(),

    );

  }

}



class MusicHomePage extends StatefulWidget {

  const MusicHomePage({super.key});

  @override

  State<MusicHomePage> createState() => _MusicHomePageState();

}



class _MusicHomePageState extends State<MusicHomePage> with WidgetsBindingObserver {

  static const channel = MethodChannel('my_music_player/media');

  final AudioPlayer player = AudioPlayer();



  List<Map<String, dynamic>> songs = [];

  List<Map<String, dynamic>> filteredSongs = [];

  List<Map<String, dynamic>> videos = [];

  Set<String> favorites = {};

  List<String> recents = [];

  Map<String, List<String>> playlists = {};

  Map<String, int> playCounts = {};

  List<String> playQueue = [];



  String currentSong = 'No song selected';

  String currentArtist = 'Unknown Artist';

  String? currentPath;

  int currentIndex = -1;



  bool scanning = false;

  bool shuffle = false;

  String repeatMode = 'off';

  bool multiSelectMode = false;

  Set<String> selectedPaths = {};

  String sortMode = 'date';

  String selectedSection = 'Tracks';



  bool playlistReady = false;

  List<String> playlistPaths = [];
  List<String> playbackScopePaths = [];
  List<String> playbackOrderPaths = [];
  bool _rebuildingPlayback = false;
  bool _playingCollection = false;
  bool _advancingPlayback = false;
  bool _completionPending = false;
  int _lastPersistedPositionMs = -5000;
  // The player keeps a tiny rolling window (previous/current/next) loaded in
  // just_audio. This keeps the notification's Previous/Play-Pause/Next
  // controls available without loading the entire music library.



  @override

  void initState() {

    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initializeApp();
    });

    player.processingStateStream.listen((state) {

      if (state == ProcessingState.completed) _handleSongCompleted();

    });

    // Persist the playback position periodically so swiping the app away from
    // Recents does not lose the last known position if Android kills the UI.
    player.positionStream.listen((position) {
      final ms = position.inMilliseconds;
      if (currentPath != null && (ms - _lastPersistedPositionMs).abs() >= 5000) {
        _lastPersistedPositionMs = ms;
        unawaited(_savePlaybackState());
      }
    });

    player.currentIndexStream.listen((index) {

      // Only a small rolling window (up to three AudioSources) is loaded for
      // performance. playlistPaths represents that window; playbackOrderPaths
      // keeps the full logical order. Keep the UI song in sync with the window.
      if (player.sequence.length != playlistPaths.length) return;
      if (index == null || index < 0 || index >= playlistPaths.length) return;

      final path = playlistPaths[index];

      final matches = songs.where((s) => '${s['path']}' == path).toList();

      if (matches.isEmpty || !mounted) return;

      final song = matches.first;

      // A queued song is consumed when playback naturally reaches it.
      if (playQueue.contains(path)) {
        playQueue.remove(path);
        _saveData();
      }

      setState(() {
        currentSong = '${song['title'] ?? 'Unknown Song'}';
        currentArtist = '${song['artist'] ?? 'Unknown Artist'}';
        currentPath = path;
        currentIndex = songs.indexWhere((s) => '${s['path']}' == path);
      });
      _savePlaybackState();

      // If the notification's Next/Previous button moved inside the rolling
      // window, recenter the window so the following Next/Previous actions
      // remain available without loading the whole library.
      final windowIndex = playlistPaths.indexOf(path);
      if (!_rebuildingPlayback &&
          playbackOrderPaths.length > 2 &&
          windowIndex >= 0 &&
          (windowIndex == 0 || windowIndex == playlistPaths.length - 1)) {
        unawaited(_recenterAfterWindowMove(path));
      }

    });

  }



  Future<void> _recenterAfterWindowMove(String path) async {
    if (_rebuildingPlayback || _advancingPlayback || !mounted) return;
    if (!playbackOrderPaths.contains(path)) return;

    // Give the player state a moment to settle before replacing the small
    // rolling source window.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    if (!mounted || currentPath != path) return;

    final position = player.position;
    final wasPlaying = player.playing;

    _rebuildingPlayback = true;
    try {
      await _loadRollingWindow(
        path,
        initialPosition: position,
        autoplay: wasPlaying,
      );
    } finally {
      _rebuildingPlayback = false;
      _processPendingCompletionIfNeeded();
    }
  }

  Future<void> _initializeApp() async {
    // Load saved settings before scanning so sort/queue/playback state
    // cannot race with the first media scan.
    await _loadSavedData();
    if (!mounted) return;
    await _requestPermissionsAndScan();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _savePlaybackState();
    }
  }

  Future<void> _savePlaybackState() async {
    final path = currentPath;
    if (path == null || path.isEmpty) return;
    final positionMs = player.position.inMilliseconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastPlayedPath', path);
    await prefs.setInt('lastPlayedPositionMs', positionMs);
  }

  Future<void> _requestPermissionsAndScan() async {

    // Android 13+ requires notification permission for the media notification.
    // Request it before starting playback so the background controls can appear.
    if (Platform.isAndroid) {
      final notification = await Permission.notification.request();
      if (mounted && !notification.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Notifications are disabled. Enable notifications to see background and lock-screen music controls.',
            ),
          ),
        );
      }
    }

    final audio = await Permission.audio.request();

    if (!audio.isGranted) {

      if (!mounted) return;

      await showDialog<void>(

        context: context,

        builder: (_) => AlertDialog(

          title: const Text('Permissions Required'),

          content: const Text(

            'Music Player needs access to music, photos and videos to build the offline library.',

          ),

          actions: [

            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),

            FilledButton(

              onPressed: () async {

                Navigator.pop(context);

                await openAppSettings();

              },

              child: const Text('Open Settings'),

            ),

          ],

        ),

      );

      return;

    }

    await scanAll();

  }



  Future<void> _loadSavedData() async {

    final prefs = await SharedPreferences.getInstance();

    Map<String, List<String>> loadedPlaylists = {};

    final playlistData = prefs.getString('playlists');

    if (playlistData != null) {

      try {

        final decoded = jsonDecode(playlistData) as Map<String, dynamic>;

        loadedPlaylists = decoded.map(

          (key, value) => MapEntry(key, List<String>.from(value as List)),

        );

      } catch (_) {}

    }



    Map<String, int> loadedCounts = {};

    final countData = prefs.getString('playCounts');

    if (countData != null) {

      try {

        final decoded = jsonDecode(countData) as Map<String, dynamic>;

        loadedCounts = decoded.map(

          (key, value) => MapEntry(key, (value as num).toInt()),

        );

      } catch (_) {}

    }



    if (!mounted) return;

    setState(() {

      favorites = prefs.getStringList('favorites')?.toSet() ?? {};

      recents = prefs.getStringList('recents') ?? [];

      playlists = loadedPlaylists;

      playCounts = loadedCounts;

      playQueue = prefs.getStringList('playQueue') ?? [];

      sortMode = prefs.getString('sortMode') ?? 'date';

      shuffle = prefs.getBool('playbackShuffle') ?? false;

      final savedRepeat = prefs.getString('playbackRepeatMode') ?? 'off';
      repeatMode = savedRepeat == 'one' || savedRepeat == 'all'
          ? savedRepeat
          : 'off';

    });

  }



  Future<void> _saveData() async {

    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList('favorites', favorites.toList());

    await prefs.setStringList('recents', recents);

    await prefs.setString('playlists', jsonEncode(playlists));

    await prefs.setString('playCounts', jsonEncode(playCounts));

    await prefs.setStringList('playQueue', playQueue);

    await prefs.setString('sortMode', sortMode);

    await prefs.setBool('playbackShuffle', shuffle);

    await prefs.setString('playbackRepeatMode', repeatMode);

  }



  Future<void> scanAll() async {
    if (scanning) return;

    if (mounted) {
      setState(() => scanning = true);
    }

    try {
      final result = await channel.invokeMethod('getSongs');
      final loaded = (result as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((e) => '${e['path'] ?? ''}'.isNotEmpty)
          .toList();

      _applySort(loaded);

      if (!mounted) return;

      setState(() {
        songs = loaded;
        filteredSongs = List<Map<String, dynamic>>.from(loaded);
        scanning = false;
        playlistReady = false;
        playlistPaths = [];
        playbackOrderPaths = [];
      });

      // Scanning only builds the library. It must NOT build a huge audio
      // source list or start the last song automatically.
      await _restoreLastPlayback(autoPlay: false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan complete: ${loaded.length} song(s) found')),
        );
      }

      // Video scanning is intentionally secondary. A slow/failed video scan
      // must never delay or interrupt the music library.
      Future<void>.delayed(const Duration(milliseconds: 300), () async {
        try {
          final videoPermission = await Permission.videos.request();
          if (!videoPermission.isGranted) return;

          final videoResult = await channel.invokeMethod('getVideos');
          final loadedVideos = (videoResult as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();

          if (mounted) setState(() => videos = loadedVideos);
        } catch (_) {
          // Music scanning/playback must continue even if video scanning fails.
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => scanning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Media scan failed: $e')),
      );
    }
  }

  Future<void> _restoreLastPlayback({bool autoPlay = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final lastPath = prefs.getString('lastPlayedPath');
    final positionMs = prefs.getInt('lastPlayedPositionMs') ?? 0;

    if (lastPath == null || lastPath.isEmpty || !mounted) return;

    final matches = songs.where(
      (s) => '${s['path'] ?? ''}' == lastPath,
    ).toList();
    if (matches.isEmpty) return;

    final song = matches.first;

    final restoredPosition = Duration(
      milliseconds: positionMs.clamp(0, 24 * 60 * 60 * 1000).toInt(),
    );

    // Rebuild the player's source window at the saved position but do not
    // autoplay on launch. The Play button/notification can resume from here.
    setState(() {
      currentSong = '${song['title'] ?? 'Unknown Song'}';
      currentArtist = '${song['artist'] ?? 'Unknown Artist'}';
      currentPath = lastPath;
      currentIndex = songs.indexWhere(
        (s) => '${s['path'] ?? ''}' == lastPath,
      );
    });

    try {
      await _preparePlaylist(
        startPath: lastPath,
        initialPosition: restoredPosition,
        autoplay: autoPlay,
      );
      await _applyRepeatMode(repeatMode);
    } catch (_) {
      // A stale saved file must never close the screen.
    }
  }

  void _applySort(List<Map<String, dynamic>> list) {

    list.sort((a, b) {

      if (sortMode == 'title') {

        return '${a['title'] ?? ''}'.toLowerCase().compareTo(

              '${b['title'] ?? ''}'.toLowerCase(),

            );

      }

      if (sortMode == 'play') {

        return (playCounts['${b['path'] ?? ''}'] ?? 0).compareTo(

              playCounts['${a['path'] ?? ''}'] ?? 0,

            );

      }

      return (int.tryParse('${b['dateAdded'] ?? 0}') ?? 0).compareTo(

            int.tryParse('${a['dateAdded'] ?? 0}') ?? 0,

          );

    });

  }



  void searchSongs(String value) {

    final query = value.trim().toLowerCase();

    setState(() {

      filteredSongs = songs.where((song) {

        final title = '${song['title'] ?? ''}'.toLowerCase();

        final artist = '${song['artist'] ?? ''}'.toLowerCase();

        final album = '${song['album'] ?? ''}'.toLowerCase();

        final folder = '${song['folder'] ?? ''}'.toLowerCase();

        return query.isEmpty ||

            title.contains(query) ||

            artist.contains(query) ||

            album.contains(query) ||

            folder.contains(query);

      }).toList();

    });

  }



  Future<List<Map<String, dynamic>>> _buildPlaybackOrder(String startPath) async {
    final scope = playbackScopePaths.isEmpty
        ? List<Map<String, dynamic>>.from(songs)
        : songs.where((s) {
            return playbackScopePaths.contains('${s['path'] ?? ''}');
          }).toList();

    final byPath = <String, Map<String, dynamic>>{
      for (final song in songs)
        if ('${song['path'] ?? ''}'.isNotEmpty)
          '${song['path']}': song,
    };

    final queueSet = playQueue.toSet();
    final seen = <String>{};
    final order = <Map<String, dynamic>>[];

    void addPath(String path) {
      if (path.isEmpty || !seen.add(path)) return;
      final song = byPath[path];
      if (song != null) order.add(song);
    }

    addPath(startPath);

    // Queue has priority and is kept ahead of the normal library order.
    for (final path in playQueue) {
      if (path != startPath) addPath(path);
    }

    final remaining = <Map<String, dynamic>>[];
    for (final song in scope) {
      final path = '${song['path'] ?? ''}';
      if (path.isEmpty || seen.contains(path) || queueSet.contains(path)) {
        continue;
      }
      remaining.add(song);
    }

    if (shuffle) {
      remaining.shuffle();
    } else {
      final startIndex = scope.indexWhere(
        (s) => '${s['path'] ?? ''}' == startPath,
      );
      if (startIndex >= 0) {
        final after = scope.sublist(startIndex + 1);
        final before = scope.sublist(0, startIndex);

        remaining
          ..clear()
          ..addAll(after.where(
            (s) => !queueSet.contains('${s['path'] ?? ''}'),
          ))
          ..addAll(before.where(
            (s) => !queueSet.contains('${s['path'] ?? ''}'),
          ));
      }
    }

    for (final song in remaining) {
      addPath('${song['path'] ?? ''}');
    }

    return order;
  }

  Future<Map<String, dynamic>> _withNotificationArtwork(
    Map<String, dynamic> song,
  ) async {
    final existing = '${song['albumArt'] ?? ''}';
    if (existing.isNotEmpty && existing != 'null' && File(existing).existsSync()) {
      return song;
    }

    try {
      final bytes = await channel.invokeMethod<Uint8List>(
        'getArtwork',
        {
          'uri': '${song['uri'] ?? ''}',
          'path': '${song['path'] ?? ''}',
        },
      );

      if (bytes == null || bytes.isEmpty) return song;

      final id = '${song['id'] ?? song['path'] ?? DateTime.now().microsecondsSinceEpoch}';
      final file = File('${Directory.systemTemp.path}/my_music_player_art_$id');
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        await file.writeAsBytes(bytes, flush: false);
      }

      return <String, dynamic>{...song, 'albumArt': file.path};
    } catch (_) {
      // Artwork is optional. Playback must continue even when extraction fails.
      return song;
    }
  }

  AudioSource _audioSourceFor(Map<String, dynamic> song) {
    final path = '${song['path'] ?? ''}';
    final uri = '${song['uri'] ?? ''}';

    final artPath = '${song['albumArt'] ?? ''}';
    final tag = MediaItem(
      id: uri.isNotEmpty ? uri : path,
      title: '${song['title'] ?? 'Unknown Song'}',
      artist: '${song['artist'] ?? 'Unknown Artist'}',
      album: '${song['album'] ?? 'Unknown Album'}',
      artUri: artPath.isNotEmpty && artPath != 'null' && File(artPath).existsSync()
          ? Uri.file(artPath)
          : null,
      duration: Duration(
        milliseconds: int.tryParse('${song['duration'] ?? 0}') ?? 0,
      ),
    );

    if (uri.isNotEmpty && uri != 'null') {
      return AudioSource.uri(Uri.parse(uri), tag: tag);
    }

    return AudioSource.file(path, tag: tag);
  }



  Future<void> _loadPlaybackOrder(
    List<Map<String, dynamic>> order, {
    Duration initialPosition = Duration.zero,
    bool autoplay = true,
  }) async {
    if (order.isEmpty || _rebuildingPlayback) return;

    _rebuildingPlayback = true;
    try {
      playbackOrderPaths = order
          .map((s) => '${s['path'] ?? ''}')
          .where((p) => p.isNotEmpty)
          .toList();

      if (playbackOrderPaths.isEmpty) return;

      final centerPath = playbackOrderPaths.first;
      await _loadRollingWindow(
        centerPath,
        initialPosition: initialPosition,
        autoplay: autoplay,
      );
    } finally {
      _rebuildingPlayback = false;
      _processPendingCompletionIfNeeded();
    }
  }

  Future<void> _loadRollingWindow(
    String centerPath, {
    Duration initialPosition = Duration.zero,
    bool autoplay = true,
  }) async {
    if (centerPath.isEmpty || playbackOrderPaths.isEmpty) return;

    final center = playbackOrderPaths.indexOf(centerPath);
    if (center < 0) return;

    final windowPaths = <String>[];
    void addUnique(String path) {
      if (path.isNotEmpty && !windowPaths.contains(path)) {
        windowPaths.add(path);
      }
    }

    final total = playbackOrderPaths.length;

    // Keep previous/current/next available to the media notification.
    if (total >= 3) {
      addUnique(playbackOrderPaths[(center - 1 + total) % total]);
      addUnique(playbackOrderPaths[center]);
      addUnique(playbackOrderPaths[(center + 1) % total]);
    } else {
      for (final path in playbackOrderPaths) {
        addUnique(path);
      }
    }

    final centerWindowIndex = windowPaths.indexOf(centerPath);
    if (centerWindowIndex < 0) return;

    final byPath = <String, Map<String, dynamic>>{
      for (final song in songs)
        if ('${song['path'] ?? ''}'.isNotEmpty)
          '${song['path']}': song,
    };

    final windowSongs = <Map<String, dynamic>>[];
    for (final path in windowPaths) {
      final song = byPath[path];
      if (song != null) windowSongs.add(song);
    }

    if (windowSongs.isEmpty) return;

    final actualCenterIndex = windowSongs.indexWhere(
      (song) => '${song['path'] ?? ''}' == centerPath,
    );
    if (actualCenterIndex < 0) return;

    // Artwork is extracted only for the currently playing song, not for the
    // whole library. This keeps scanning/startup fast while still giving the
    // background notification and lock screen the song artwork.
    final artworkSong = await _withNotificationArtwork(
      windowSongs[actualCenterIndex],
    );
    windowSongs[actualCenterIndex] = artworkSong;

    await player.setAudioSources(
      windowSongs.map(_audioSourceFor).toList(),
      initialIndex: actualCenterIndex,
      initialPosition: initialPosition,
    );

    await player.setLoopMode(
      repeatMode == 'one' ? LoopMode.one : LoopMode.off,
    );
    await player.setShuffleModeEnabled(false);

    playlistPaths = windowSongs
        .map((song) => '${song['path'] ?? ''}')
        .toList();
    playlistReady = true;

    if (mounted) {
      final song = windowSongs[actualCenterIndex];
      final path = '${song['path'] ?? ''}';
      final libraryIndex = songs.indexWhere(
        (s) => '${s['path'] ?? ''}' == path,
      );
      if (libraryIndex >= 0 && '${song['albumArt'] ?? ''}'.isNotEmpty) {
        final updated = Map<String, dynamic>.from(song);
        songs[libraryIndex] = updated;
        final filteredIndex = filteredSongs.indexWhere(
          (s) => '${s['path'] ?? ''}' == path,
        );
        if (filteredIndex >= 0) {
          filteredSongs[filteredIndex] = updated;
        }
      }
      setState(() {
        currentPath = path;
        currentSong = '${song['title'] ?? 'Unknown Song'}';
        currentArtist = '${song['artist'] ?? 'Unknown Artist'}';
        currentIndex = libraryIndex;
      });
    }

    if (autoplay) await player.play();
  }

  

  Future<void> _preparePlaylist({
    String? startPath,
    Duration initialPosition = Duration.zero,
    bool autoplay = true,
  }) async {
    if (songs.isEmpty) return;

    final path = startPath ?? currentPath ?? '${songs.first['path'] ?? ''}';
    if (path.isEmpty) return;

    final order = await _buildPlaybackOrder(path);
    if (order.isEmpty) return;

    await _loadPlaybackOrder(
      order,
      initialPosition: initialPosition,
      autoplay: autoplay,
    );
  }

  Future<void> playSong(
    Map<String, dynamic> song, {
    Duration startPosition = Duration.zero,
  }) async {
    final path = '${song['path'] ?? ''}';
    if (path.isEmpty || songs.isEmpty) return;

    final index = songs.indexWhere((s) => '${s['path'] ?? ''}' == path);
    if (index < 0) return;

    if (!_playingCollection &&
        playbackScopePaths.isNotEmpty &&
        !playbackScopePaths.contains(path)) {
      playbackScopePaths = [];
    }

    try {
      // If the same file is already loaded, do not rebuild anything.
      if (playlistReady && currentPath == path) {
        await player.seek(startPosition);
        await player.play();
      } else {
        await _preparePlaylist(
          startPath: path,
          initialPosition: startPosition,
          autoplay: true,
        );
      }

      if (!mounted) return;

      setState(() {
        currentSong = '${song['title'] ?? 'Unknown Song'}';
        currentArtist = '${song['artist'] ?? 'Unknown Artist'}';
        currentPath = path;
        currentIndex = index;
        playCounts[path] = (playCounts[path] ?? 0) + 1;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastPlayedPath', path);
      await prefs.setInt('lastPlayedPositionMs', startPosition.inMilliseconds);

      playQueue.remove(path);

      recents.remove(path);
      recents.insert(0, path);
      if (recents.length > 50) {
        recents = recents.sublist(0, 50);
      }

      await _saveData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play song: $e')),
      );
    }
  }

  Future<void> _playCollection(
    List<Map<String, dynamic>> list, {
    bool shuffleOrder = false,
  }) async {
    if (list.isEmpty) return;

    final valid = list
        .where((s) => '${s['path'] ?? ''}'.isNotEmpty)
        .toList();
    if (valid.isEmpty) return;

    playbackScopePaths = valid.map((s) => '${s['path']}').toList();

    if (mounted) {
      setState(() => shuffle = shuffleOrder);
    } else {
      shuffle = shuffleOrder;
    }

    final start = shuffleOrder
        ? (List<Map<String, dynamic>>.from(valid)..shuffle()).first
        : valid.first;

    _playingCollection = true;
    try {
      await playSong(start);
    } finally {
      _playingCollection = false;
    }
  }

  Future<void> _applyRepeatMode(String mode) async {
    final normalized = mode == 'one' || mode == 'all' ? mode : 'off';

    // Only Repeat One needs just_audio's built-in loop. Repeat All and the
    // normal continuous player are handled by our path-based navigator.
    await player.setLoopMode(
      normalized == 'one' ? LoopMode.one : LoopMode.off,
    );

    if (mounted && repeatMode != normalized) {
      setState(() => repeatMode = normalized);
    } else {
      repeatMode = normalized;
    }
    await _saveData();
  }

  Future<void> _startPath(
    String path, {
    Duration position = Duration.zero,
  }) async {
    if (path.isEmpty) return;

    final matches = songs.where(
      (s) => '${s['path'] ?? ''}' == path,
    ).toList();
    if (matches.isEmpty) return;

    final song = matches.first;

    // Rebuild the logical order only when the requested path is not part of
    // the current order. The actual player receives only a 2-3 song window.
    if (playbackOrderPaths.isEmpty ||
        !playbackOrderPaths.contains(path)) {
      playbackOrderPaths = (await _buildPlaybackOrder(path))
          .map((s) => '${s['path'] ?? ''}')
          .where((p) => p.isNotEmpty)
          .toList();
    }

    if (playbackOrderPaths.isEmpty) return;

    await _loadRollingWindow(
      path,
      initialPosition: position,
      autoplay: true,
    );

    if (!mounted) return;

    setState(() {
      currentPath = path;
      currentSong = '${song['title'] ?? 'Unknown Song'}';
      currentArtist = '${song['artist'] ?? 'Unknown Artist'}';
      currentIndex = songs.indexWhere(
        (s) => '${s['path'] ?? ''}' == path,
      );
      playCounts[path] = (playCounts[path] ?? 0) + 1;
    });

    recents.remove(path);
    recents.insert(0, path);
    if (recents.length > 50) {
      recents = recents.sublist(0, 50);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastPlayedPath', path);
    await prefs.setInt('lastPlayedPositionMs', position.inMilliseconds);
    await _saveData();
  }

  Future<void> _handleSongCompleted() async {
    if (!mounted) return;

    // Repeat One is handled by just_audio itself.
    if (repeatMode == 'one') return;

    // A source-window recenter briefly replaces the sources. Preserve a
    // completion event during that operation rather than accidentally
    // stopping at the end of a track.
    if (_rebuildingPlayback) {
      _completionPending = true;
      return;
    }
    if (_advancingPlayback) return;

    _advancingPlayback = true;
    try {
      await nextSong();
    } catch (error) {
      // A bad/deleted file must not crash the widget tree. The error is
      // visible so the user can rescan the library or remove the file.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not continue playback: $error')),
        );
      }
    } finally {
      _advancingPlayback = false;
      _processPendingCompletionIfNeeded();
    }
  }

  void _processPendingCompletionIfNeeded() {
    if (!_completionPending ||
        _rebuildingPlayback ||
        _advancingPlayback ||
        !mounted) {
      return;
    }

    _completionPending = false;
    if (repeatMode != 'one' &&
        player.processingState == ProcessingState.completed) {
      unawaited(_handleSongCompleted());
    }
  }

  // ignore: unused_element
  Future<void> _playFromSource(Map<String, dynamic> song) async {
    if (playbackScopePaths.isEmpty) {
      await playSong(song);
      return;
    }
    _playingCollection = true;
    try {
      await playSong(song);
    } finally {
      _playingCollection = false;
    }
  }

  Future<void> nextSong() async {
    if (songs.isEmpty) return;

    // Queue always has priority.
    while (playQueue.isNotEmpty) {
      final queuedPath = playQueue.removeAt(0);
      await _saveData();

      final exists = songs.any(
        (s) => '${s['path'] ?? ''}' == queuedPath,
      );
      if (!exists) continue;

      await _startPath(queuedPath);
      return;
    }

    if (currentPath == null || currentPath!.isEmpty) {
      await playSong(songs.first);
      return;
    }

    if (playbackOrderPaths.isEmpty ||
        !playbackOrderPaths.contains(currentPath)) {
      playbackOrderPaths = (await _buildPlaybackOrder(currentPath!))
          .map((s) => '${s['path'] ?? ''}')
          .where((p) => p.isNotEmpty)
          .toList();
    }

    if (playbackOrderPaths.isEmpty) return;

    final current = playbackOrderPaths.indexOf(currentPath!);
    if (current < 0) return;

    // Continuous playback: after the last track, start from the first.
    final nextIndex = (current + 1) % playbackOrderPaths.length;
    await _startPath(playbackOrderPaths[nextIndex]);
  }

  Future<void> previousSong() async {
    if (songs.isEmpty || currentPath == null) return;

    if (playbackOrderPaths.isEmpty ||
        !playbackOrderPaths.contains(currentPath)) {
      playbackOrderPaths = (await _buildPlaybackOrder(currentPath!))
          .map((s) => '${s['path'] ?? ''}')
          .where((p) => p.isNotEmpty)
          .toList();
    }

    if (playbackOrderPaths.isEmpty) return;

    final current = playbackOrderPaths.indexOf(currentPath!);
    if (current < 0) return;

    final previousIndex = current <= 0
        ? playbackOrderPaths.length - 1
        : current - 1;

    await _startPath(playbackOrderPaths[previousIndex]);
  }

  Future<void> playNext(String path) async {

    // Queue changes are kept in memory and persisted immediately.
    // Do not rebuild the complete AudioPlayer source list here: that was
    // one of the main causes of a visible pause/lag when adding to queue.
    playQueue.remove(path);
    playQueue.insert(0, path);

    await _saveData();

    if (mounted) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(content: Text('Added to play next')),

      );

    }

  }



  Future<void> addToQueue(String path) async {

    // Keep the currently loaded audio sequence untouched. The queue is
    // consumed by nextSong(), so adding a track is now instantaneous.
    if (!playQueue.contains(path)) playQueue.add(path);

    await _saveData();

    if (mounted) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(content: Text('Added to play queue')),

      );

    }

  }



  void _showQueue() {

    showModalBottomSheet<void>(

      context: context,

      isScrollControlled: true,

      builder: (sheetContext) => SafeArea(

        child: SizedBox(

          height: MediaQuery.of(context).size.height * .65,

          child: Column(

            children: [

              ListTile(

                title: Text('Play queue (${playQueue.length})'),

                trailing: IconButton(

                  icon: const Icon(Icons.clear_all),

                  onPressed: () async {

                    playQueue.clear();

                    await _saveData();

                    if (sheetContext.mounted) Navigator.pop(sheetContext);

                    setState(() {});

                  },

                ),

              ),

              Expanded(

                child: playQueue.isEmpty

                    ? const Center(child: Text('Queue is empty'))

                    : ListView.builder(

                        itemCount: playQueue.length,

                        itemBuilder: (_, index) {

                          final path = playQueue[index];

                          final match = songs.where((s) => '${s['path']}' == path).toList();

                          if (match.isEmpty) return const SizedBox.shrink();

                          final song = match.first;

                          return ListTile(

                            leading: artwork(song, size: 52),

                            title: Text('${song['title'] ?? 'Unknown Song'}'),

                            subtitle: Text('${song['artist'] ?? 'Unknown Artist'}'),

                            trailing: IconButton(

                              icon: const Icon(Icons.close),

                              onPressed: () async {

                                playQueue.removeAt(index);

                                await _saveData();

                                setState(() {});

                              },

                            ),

                            onTap: () async {

                              playQueue.removeAt(index);

                              await _saveData();

                              if (sheetContext.mounted) Navigator.pop(sheetContext);

                              await playSong(song);

                            },

                          );

                        },

                      ),

              ),

            ],

          ),

        ),

      ),

    );

  }



  Future<void> _showSortOrder() async {

    final selected = await showDialog<String>(

      context: context,

      builder: (context) => SimpleDialog(

        title: const Text('Sort Order'),

        children: [

          _sortOption(context, 'title', 'Sort by song title'),

          _sortOption(context, 'date', 'Sort by date added'),

          _sortOption(context, 'play', 'Sort by play count'),

        ],

      ),

    );

    if (selected == null) return;

    final wasPlaying = player.playing;
    final position = player.position;
    setState(() {
      sortMode = selected;
      _applySort(songs);
      _applySort(filteredSongs);
      playlistReady = false;
    });
    await _saveData();
    if (currentPath != null) {
      final order = await _buildPlaybackOrder(currentPath!);
      await _loadPlaybackOrder(order, initialPosition: position, autoplay: wasPlaying);
    }

  }



  Widget _sortOption(BuildContext context, String value, String text) {

    return SimpleDialogOption(

      onPressed: () => Navigator.pop(context, value),

      child: Row(

        children: [

          Expanded(child: Text(text)),

          if (sortMode == value)

            const Icon(Icons.check, color: Colors.redAccent),

        ],

      ),

    );

  }



  void _toggleMultiSelect() {

    setState(() {

      multiSelectMode = !multiSelectMode;

      if (!multiSelectMode) selectedPaths.clear();

    });

  }



  void _toggleSelected(String path) {

    setState(() {

      if (selectedPaths.contains(path)) {

        selectedPaths.remove(path);

      } else {

        selectedPaths.add(path);

      }

    });

  }



  Future<void> _multiFavorite() async {

    setState(() => favorites.addAll(selectedPaths));

    await _saveData();

    _toggleMultiSelect();

  }



  Future<void> _multiPlaylist() async {
    final selected = selectedPaths.where((p) => p.isNotEmpty).toList();
    if (selected.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one song')),
        );
      }
      return;
    }

    String? playlistName;

    if (playlists.isEmpty) {
      playlistName = await createPlaylist();
    } else {
      playlistName = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Add selected songs to'),
          children: [
            ...playlists.keys.map(
              (name) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, name),
                child: Text(name),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, '__create__'),
              child: const Text('+ Create Playlist'),
            ),
          ],
        ),
      );

      if (playlistName == '__create__') {
        playlistName = await createPlaylist();
      }
    }

    if (playlistName == null || playlistName.isEmpty) return;

    final list = playlists[playlistName] ?? <String>[];
    for (final path in selected) {
      if (!list.contains(path)) list.add(path);
    }
    playlists[playlistName] = list;

    await _saveData();
    if (!mounted) return;
    setState(() => selectedPaths.clear());
    if (multiSelectMode) _toggleMultiSelect();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selected.length} song(s) added to "$playlistName"')),
    );
  }

  Future<void> toggleFavoriteFor(String path) async {
    if (path.isEmpty) return;

    setState(() {
      if (favorites.contains(path)) {
        favorites.remove(path);
      } else {
        favorites.add(path);
      }
    });

    await _saveData();
  }

  Future<String?> createPlaylist() async {
    final controller = TextEditingController();

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
          ),
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) {
              Navigator.pop(dialogContext, trimmed);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) {
                Navigator.pop(dialogContext, value);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (name == null || name.trim().isEmpty) return null;

    final trimmedName = name.trim();

    if (playlists.containsKey(trimmedName)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"$trimmedName" already exists')),
        );
      }
      return trimmedName;
    }

    setState(() => playlists[trimmedName] = []);
    await _saveData();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playlist "$trimmedName" created')),
      );
    }

    return trimmedName;
  }

  Future<void> addToPlaylist(String path) async {
    if (path.isEmpty) return;

    String? playlistName;

    if (playlists.isEmpty) {
      playlistName = await createPlaylist();
    } else {
      playlistName = await showDialog<String>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Add to Playlist'),
          children: [
            ...playlists.keys.map(
              (name) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, name),
                child: Text(name),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, '__create__'),
              child: const Text('+ Create Playlist'),
            ),
          ],
        ),
      );

      if (playlistName == '__create__') {
        playlistName = await createPlaylist();
      }
    }

    if (playlistName == null || playlistName.isEmpty) return;

    final list = playlists[playlistName] ?? <String>[];
    if (!list.contains(path)) {
      list.add(path);
      playlists[playlistName] = list;
      await _saveData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Song added to "$playlistName"')),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Song is already in "$playlistName"')),
      );
    }
  }

  Future<void> _showSongInfo(Map<String, dynamic> song) async {

    final path = '${song['path'] ?? ''}';

    await showDialog<void>(

      context: context,

      builder: (context) => AlertDialog(

        title: Text('${song['title'] ?? 'Song Info'}'),

        content: Text(

          'Artist: ${song['artist'] ?? 'Unknown'}\n'

          'Album: ${song['album'] ?? 'Unknown'}\n'

          'Folder: ${song['folder'] ?? 'Unknown'}\n'

          'Duration: ${_formatMs(song['duration'])}\n'

          'Play count: ${playCounts[path] ?? 0}\n\n'

          'Path: $path',

        ),

        actions: [

          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),

        ],

      ),

    );

  }



  String _formatMs(dynamic value) {

    final d = Duration(milliseconds: int.tryParse('$value') ?? 0);

    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  }



  Future<void> _shareSong(Map<String, dynamic> song) async {

    try {

      await channel.invokeMethod('shareFile', {

        'uri': '${song['uri'] ?? ''}',

        'path': '${song['path'] ?? ''}',

      });

    } catch (e) {

      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Share failed: $e')));

    }

  }



  Future<void> _setRingtone(Map<String, dynamic> song) async {

    try {

      final ok = await channel.invokeMethod('setRingtone', {

        'uri': '${song['uri'] ?? ''}',

        'name': '${song['title'] ?? 'Ringtone'}.mp3',

        'mimeType': 'audio/mpeg',

      });

      if (mounted) {

        ScaffoldMessenger.of(context).showSnackBar(

          SnackBar(content: Text(ok == true ? 'Ringtone set successfully' : 'Could not set ringtone')),

        );

      }

    } catch (e) {

      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ringtone failed: $e')));

    }

  }



  Future<void> _deleteSong(Map<String, dynamic> song) async {
    final path = '${song['path'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete song?'),
        content: Text('${song['title'] ?? 'This song'} will be removed from device storage.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final ok = await channel.invokeMethod('deleteSong', {
        'id': song['id'],
        'uri': '${song['uri'] ?? ''}',
        'path': path,
      });
      if (ok != true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Delete failed. Android permission or MediaStore access is required.')),
          );
        }
        return;
      }

      if (!mounted) return;
      setState(() {
        songs.removeWhere((s) => '${s['path']}' == path);
        filteredSongs.removeWhere((s) => '${s['path']}' == path);
        favorites.remove(path);
        recents.remove(path);
        playQueue.remove(path);
        selectedPaths.remove(path);
        if (currentPath == path) {
          currentPath = null;
          currentIndex = -1;
          player.stop();
        }
        playlistReady = false;
        playlistPaths = [];
      });
      await _saveData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Song deleted successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  void selectSection(String section) => setState(() => selectedSection = section);



  List<Map<String, dynamic>> get favoriteSongs =>

      songs.where((s) => favorites.contains('${s['path']}')).toList();



  List<Map<String, dynamic>> get recentSongs {

    final result = <Map<String, dynamic>>[];

    for (final path in recents) {

      final match = songs.where((s) => '${s['path']}' == path).toList();

      if (match.isNotEmpty) result.add(match.first);

    }

    return result;

  }



  List<String> get albums => songs.map((s) => '${s['album'] ?? 'Unknown Album'}').toSet().toList();

  List<String> get artists => songs.map((s) => '${s['artist'] ?? 'Unknown Artist'}').toSet().toList();

  List<String> get folders => songs.map((s) => '${s['folder'] ?? 'Unknown Folder'}').toSet().toList();



  List<Map<String, dynamic>> get displayedSongs {

    switch (selectedSection) {

      case 'Favorites': return favoriteSongs;

      case 'Recents': return recentSongs;

      default: return filteredSongs;

    }

  }



  Widget artwork(Map<String, dynamic> song, {double size = 56}) {
    final artPath = '${song['albumArt'] ?? ''}';

    if (artPath.isNotEmpty && artPath != 'null') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(artPath),
          key: ValueKey(artPath),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * MediaQuery.of(context).devicePixelRatio).round(),
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.grey.shade900,
            ),
            child: Icon(Icons.music_note, size: size * .48),
          ),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.grey.shade900,
      ),
      child: Icon(Icons.music_note, size: size * .48),
    );
  }



  @override

  Widget build(BuildContext context) {

    final isFavorite = currentPath != null && favorites.contains(currentPath);

    return Scaffold(

      backgroundColor: Colors.black,

      appBar: AppBar(

        backgroundColor: Colors.black,

        title: const Text('Library', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),

        actions: [

          IconButton(

            onPressed: () => showSearch(

              context: context,

              delegate: MusicSearchDelegate(songs: songs, onPlay: playSong, artwork: artwork),

            ),

            icon: const Icon(Icons.search, size: 32),

          ),

          IconButton(
            onPressed: _showPlaybackOptions,
            icon: const Icon(Icons.tune, size: 28),
            tooltip: 'Playback options',
          ),

          IconButton(onPressed: () => _showMoreMenu(context), icon: const Icon(Icons.more_horiz, size: 30)),

          const IconButton(onPressed: null, icon: Icon(Icons.account_circle_outlined, size: 32)),

        ],

      ),

      body: Column(

        children: [

          _buildQuickCards(),

          _buildTabs(),

          Expanded(child: scanning ? const Center(child: CircularProgressIndicator()) : _buildContent()),

          if (currentPath != null) _buildMiniPlayer(isFavorite),

        ],

      ),

      bottomNavigationBar: NavigationBar(

        selectedIndex: 0,

        onDestinationSelected: (index) {

          if (index == 1) {

            showSearch(

              context: context,

              delegate: MusicSearchDelegate(songs: songs, onPlay: playSong, artwork: artwork),

            );

          }

        },

        destinations: const [

          NavigationDestination(icon: Icon(Icons.headphones), label: 'Library'),

          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),

        ],

      ),

    );

  }



  Widget _buildQuickCards() {

    return SizedBox(

      height: 165,

      child: ListView(

        scrollDirection: Axis.horizontal,

        padding: const EdgeInsets.all(12),

        children: [

          _quickCard('Favorites', Icons.favorite, () => selectSection('Favorites')),

          _quickCard('Videos', Icons.video_library, () => selectSection('Videos')),

          _quickCard('Recent', Icons.history, () => selectSection('Recents')),

          _quickCard('Scan', Icons.refresh, scanAll),

        ],

      ),

    );

  }



  Widget _quickCard(String title, IconData icon, VoidCallback onTap) {

    return GestureDetector(

      onTap: onTap,

      child: Container(

        width: 145,

        margin: const EdgeInsets.only(right: 12),

        decoration: BoxDecoration(color: const Color(0xFF202020), borderRadius: BorderRadius.circular(20)),

        child: Column(

          mainAxisAlignment: MainAxisAlignment.center,

          children: [Icon(icon, size: 55), const SizedBox(height: 8), Text(title, style: const TextStyle(fontSize: 18))],

        ),

      ),

    );

  }



  Widget _buildTabs() {

    const tabs = ['Tracks', 'Albums', 'Playlists', 'Artists', 'Folders'];

    return SizedBox(

      height: 60,

      child: ListView.builder(

        scrollDirection: Axis.horizontal,

        itemCount: tabs.length,

        itemBuilder: (_, index) {

          final tab = tabs[index];

          final selected = selectedSection == tab;

          return GestureDetector(

            onTap: () => selectSection(tab),

            child: Container(

              margin: const EdgeInsets.symmetric(horizontal: 14),

              alignment: Alignment.center,

              decoration: BoxDecoration(

                border: selected ? const Border(bottom: BorderSide(width: 3, color: Colors.white)) : null,

              ),

              child: Text(

                tab,

                style: TextStyle(fontSize: 21, color: selected ? Colors.white : Colors.grey, fontWeight: selected ? FontWeight.bold : FontWeight.normal),

              ),

            ),

          );

        },

      ),

    );

  }



  Widget _buildContent() {

    switch (selectedSection) {

      case 'Albums': return _buildAlbums();

      case 'Artists': return _buildArtists();

      case 'Folders': return _buildFolders();

      case 'Playlists': return _buildPlaylists();

      case 'Videos': return _buildVideos();

      case 'Favorites': return _buildSongList(favoriteSongs);

      case 'Recents': return _buildSongList(recentSongs);

      default: return _buildTracks();

    }

  }



  Widget _buildTracks() {
    final list = displayedSongs;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _showPlaybackOptions,
                  icon: Icon(shuffle ? Icons.shuffle_on : Icons.tune),
                  label: const Text('Playback Options'),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${list.length} songs',
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
        if (multiSelectMode)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('${selectedPaths.length} selected'),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      selectedPaths = list
                          .map((song) => '${song['path'] ?? ''}')
                          .where((path) => path.isNotEmpty)
                          .toSet();
                    });
                  },
                  child: const Text('Select all'),
                ),
                IconButton(
                  onPressed: _multiFavorite,
                  icon: const Icon(Icons.favorite),
                  tooltip: 'Favorite selected',
                ),
                IconButton(
                  onPressed: _multiPlaylist,
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to playlist',
                ),
                IconButton(
                  onPressed: _toggleMultiSelect,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        Expanded(child: _buildSongList(list)),
      ],
    );
  }

  Future<void> _setShuffle(bool value) async {
    setState(() => shuffle = value);
    await _saveData();
    if (currentPath == null || songs.isEmpty) return;
    final wasPlaying = player.playing;
    final position = player.position;
    final order = await _buildPlaybackOrder(currentPath!);
    await _loadPlaybackOrder(order, initialPosition: position, autoplay: wasPlaying);
  }

  void _showPlaybackOptions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              const ListTile(
                title: Text(
                  'Playback Options',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              SwitchListTile(
                secondary: Icon(shuffle ? Icons.shuffle_on : Icons.shuffle),
                title: const Text('Shuffle'),
                subtitle: Text(shuffle ? 'Shuffle is ON' : 'Shuffle is OFF'),
                value: shuffle,
                onChanged: (value) {
                  _setShuffle(value);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: Icon(Icons.repeat, color: repeatMode == 'off' ? null : Colors.redAccent),
                title: const Text('Repeat'),
                subtitle: Text(repeatMode == 'one' ? 'Repeat One' : repeatMode == 'all' ? 'Repeat All' : 'Repeat Off'),
                onTap: () async {
                  final next = repeatMode == 'off' ? 'one' : repeatMode == 'one' ? 'all' : 'off';
                  setState(() => repeatMode = next);
                  await _applyRepeatMode(next);
                  await _saveData();
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Play Queue'),
                subtitle: Text('${playQueue.length} song(s) in queue'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showQueue();
                },
              ),
              ListTile(
                leading: const Icon(Icons.sort),
                title: const Text('Sort Order'),
                subtitle: Text(
                  sortMode == 'title'
                      ? 'Song title'
                      : sortMode == 'date'
                          ? 'Date added'
                          : 'Play count',
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showSortOrder();
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('Multi-select'),
                subtitle: const Text('Select multiple songs'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleMultiSelect();
                },
              ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSongList(List<Map<String, dynamic>> list) {

    if (list.isEmpty) return const Center(child: Text('No songs found', style: TextStyle(color: Colors.grey, fontSize: 18)));

    return ListView.builder(

      itemCount: list.length,

      itemBuilder: (_, index) {

        final song = list[index];

        final path = '${song['path'] ?? ''}';

        final playing = currentPath == path;

        final fav = favorites.contains(path);

        return ListTile(

          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),

          leading: Row(

            mainAxisSize: MainAxisSize.min,

            children: [

              if (multiSelectMode)

                Checkbox(value: selectedPaths.contains(path), onChanged: (_) => _toggleSelected(path)),

              artwork(song, size: 62),

            ],

          ),

          title: Text(

            '${song['title'] ?? 'Unknown Song'}',

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: playing ? Colors.redAccent : Colors.white),

          ),

          subtitle: Text(

            '${song['artist'] ?? 'Unknown Artist'}',

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: TextStyle(color: playing ? Colors.redAccent : Colors.grey),

          ),

          trailing: Row(

            mainAxisSize: MainAxisSize.min,

            children: [

              if (playing)

                StreamBuilder<bool>(

                  stream: player.playingStream,

                  builder: (_, snapshot) => Icon(snapshot.data == true ? Icons.equalizer : Icons.play_arrow, color: Colors.redAccent),

                ),

              if (!multiSelectMode)

                IconButton(

                  onPressed: () => toggleFavoriteFor(path),

                  icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.red : Colors.grey),

                ),

              if (!multiSelectMode)

                PopupMenuButton<String>(

                  onSelected: (value) {

                    switch (value) {

                      case 'play_next': playNext(path); break;

                      case 'queue': addToQueue(path); break;

                      case 'playlist': addToPlaylist(path); break;

                      case 'album':

                        _showSongListPage(

                          '${song['album'] ?? 'Album'}',

                          songs.where((s) => '${s['album']}' == '${song['album']}').toList(),

                        );

                        break;

                      case 'info': _showSongInfo(song); break;

                      case 'ringtone': _setRingtone(song); break;

                      case 'share': _shareSong(song); break;

                      case 'delete': _deleteSong(song); break;

                    }

                  },

                  itemBuilder: (_) => const [

                    PopupMenuItem(value: 'play_next', child: Text('Play next')),

                    PopupMenuItem(value: 'queue', child: Text('Add to play queue')),

                    PopupMenuItem(value: 'playlist', child: Text('Add to Playlist')),

                    PopupMenuItem(value: 'album', child: Text('Album')),

                    PopupMenuItem(value: 'info', child: Text('Song Info')),

                    PopupMenuItem(value: 'ringtone', child: Text('Set as Ringtone')),

                    PopupMenuItem(value: 'share', child: Text('Share file')),

                    PopupMenuItem(value: 'delete', child: Text('Delete')),

                  ],

                ),

            ],

          ),

          onTap: () => multiSelectMode ? _toggleSelected(path) : playSong(song),

          onLongPress: () {

            if (!multiSelectMode) {

              setState(() {

                multiSelectMode = true;

                selectedPaths.add(path);

              });

            } else {

              _toggleSelected(path);

            }

          },

        );

      },

    );

  }



  Widget _buildAlbums() {

    if (albums.isEmpty) return const Center(child: Text('No albums found'));

    return GridView.builder(

      padding: const EdgeInsets.all(16),

      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: .85, crossAxisSpacing: 12, mainAxisSpacing: 12),

      itemCount: albums.length,

      itemBuilder: (_, index) {

        final album = albums[index];

        final list = songs.where((s) => '${s['album']}' == album).toList();

        return GestureDetector(

          onTap: () => _showSongListPage(album, list),

          child: Card(

            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [

              artwork(list.first, size: 120),

              const SizedBox(height: 8),

              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(album, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis)),

            ]),

          ),

        );

      },

    );

  }



  Widget _buildArtists() {

    return ListView.builder(

      itemCount: artists.length,

      itemBuilder: (_, index) {

        final artist = artists[index];

        final list = songs.where((s) => '${s['artist']}' == artist).toList();

        return ListTile(

          leading: const CircleAvatar(child: Icon(Icons.person)),

          title: Text(artist),

          subtitle: Text('${list.length} songs'),

          onTap: () => _showSongListPage(artist, list),

        );

      },

    );

  }



  Widget _buildFolders() {

    return ListView.builder(

      itemCount: folders.length,

      itemBuilder: (_, index) {

        final folder = folders[index];

        final list = songs.where((s) => '${s['folder']}' == folder).toList();

        return ListTile(

          leading: const Icon(Icons.folder, size: 38),

          title: Text(folder),

          subtitle: Text('${list.length} songs'),

          onTap: () => _showSongListPage(folder, list),

        );

      },

    );

  }



  Future<void> _renamePlaylist(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Playlist'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Playlist name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () { final name = controller.text.trim(); if (name.isNotEmpty) Navigator.pop(dialogContext, name); }, child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.trim().isEmpty || newName.trim() == oldName) return;
    final trimmed = newName.trim();
    if (playlists.containsKey(trimmed)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playlist "$trimmed" already exists')));
      return;
    }
    final list = playlists.remove(oldName);
    if (list == null) return;
    setState(() => playlists[trimmed] = list);
    await _saveData();
  }

  Future<void> _deletePlaylist(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Playlist?'),
        content: Text('Delete "$name"? The music files will not be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => playlists.remove(name));
    await _saveData();
  }

  Future<void> _addSongsToPlaylist(String playlistName) async {
    final available = songs.where((song) {
      final path = '${song['path'] ?? ''}';
      return path.isNotEmpty && !(playlists[playlistName] ?? []).contains(path);
    }).toList();
    if (available.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No more songs to add')));
      return;
    }
    final selected = <String>{};
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: const Text('Add Songs'),
          content: SizedBox(
            width: double.maxFinite, height: MediaQuery.of(context).size.height * .55,
            child: ListView.builder(
              itemCount: available.length,
              itemBuilder: (_, index) {
                final song = available[index];
                final path = '${song['path'] ?? ''}';
                return CheckboxListTile(
                  value: selected.contains(path),
                  onChanged: (value) => dialogSetState(() {
                    if (value == true) {
                      selected.add(path);
                    } else {
                      selected.remove(path);
                    }
                  }),
                  title: Text('${song['title'] ?? 'Unknown Song'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${song['artist'] ?? 'Unknown Artist'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text('Add (${selected.length})')),
          ],
        ),
      ),
    );
    if (result != true || selected.isEmpty) return;
    final list = playlists[playlistName] ?? <String>[];
    for (final path in selected) { if (!list.contains(path)) list.add(path); }
    setState(() => playlists[playlistName] = list);
    await _saveData();
  }

  Widget _buildPlaylists() {
    return Column(
      children: [
        Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.all(12), child: FilledButton.icon(onPressed: createPlaylist, icon: const Icon(Icons.add), label: const Text('New Playlist')))),
        Expanded(
          child: playlists.isEmpty
              ? const Center(child: Text('No playlists yet'))
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (_, index) {
                    final name = playlists.keys.elementAt(index);
                    final paths = playlists[name] ?? [];
                    final list = songs.where((s) => paths.contains('${s['path']}')).toList();
                    return ListTile(
                      leading: list.isEmpty ? const Icon(Icons.queue_music, size: 35) : artwork(list.first, size: 62),
                      title: Text(name), subtitle: Text('${list.length} songs'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          switch (value) {
                            case 'add': _addSongsToPlaylist(name); break;
                            case 'rename': _renamePlaylist(name); break;
                            case 'delete': _deletePlaylist(name); break;
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'add', child: Text('Add Songs')),
                          PopupMenuItem(value: 'rename', child: Text('Rename Playlist')),
                          PopupMenuItem(value: 'delete', child: Text('Delete Playlist')),
                        ],
                      ),
                      onTap: () => _showSongListPage(name, list, playlistName: name),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildVideos() {

    if (videos.isEmpty) return const Center(child: Text('No videos found'));

    return ListView.builder(

      itemCount: videos.length,

      itemBuilder: (_, index) {

        final video = videos[index];

        final name = '${video['name'] ?? 'Video'}';

        final path = '${video['path'] ?? ''}';

        return ListTile(

          leading: const Icon(Icons.video_library, size: 40),

          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),

          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPage(path: path, title: name))),

        );

      },

    );

  }




  Widget _buildMiniPlayer(bool isFavorite) {

    final match = songs.where((s) => '${s['path']}' == currentPath).toList();

    final song = match.isEmpty ? {'title': currentSong, 'artist': currentArtist, 'path': currentPath} : match.first;

    return GestureDetector(

      onTap: () => Navigator.push(

        context,

        MaterialPageRoute(

          builder: (_) => NowPlayingPage(

            player: player,

            song: song,

            librarySongs: songs,

            isFavoriteFor: (path) => favorites.contains(path),

            isFavorite: isFavorite,

            shuffle: shuffle,

            repeatMode: repeatMode,

            onFavorite: () {

              if (currentPath != null) {

                toggleFavoriteFor(currentPath!);

              }

            },

            onPrevious: previousSong,

            onNext: nextSong,

            onShuffle: _setShuffle,

            onRepeatModeChanged: (mode) {
              setState(() => repeatMode = mode);
              _applyRepeatMode(mode);
            },

            onQueue: _showQueue,
            onSortOrder: _showSortOrder,
            onMultiSelect: _toggleMultiSelect,

          ),

        ),

      ),

      child: Container(

        height: 75,

        margin: const EdgeInsets.symmetric(horizontal: 12),

        decoration: BoxDecoration(color: const Color(0xFF3D3D3D), borderRadius: BorderRadius.circular(16)),

        child: Row(

          children: [

            StreamBuilder<bool>(
              stream: player.playingStream,
              builder: (_, snapshot) => PlayingArtwork(
                song: song,
                size: 58,
                playing: snapshot.data == true && currentPath == '${song['path']}',
                artwork: artwork,
              ),
            ),

            const SizedBox(width: 10),

            Expanded(

              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [

                Text(currentSong, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),

                Text(currentArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey)),

              ]),

            ),

            StreamBuilder<PlayerState>(

              stream: player.playerStateStream,

              builder: (_, snapshot) {

                final playing = snapshot.data?.playing ?? player.playing;

                return IconButton(

                  onPressed: () => playing ? player.pause() : player.play(),

                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),

                  iconSize: 32,

                );

              },

            ),


          ],

        ),

      ),

    );

  }



  void _showSongListPage(String title, List<Map<String, dynamic>> list, {String? playlistName}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SongListPage(
          title: title,
          songs: list,
          onPlay: playlistName == null
              ? playSong
              : (song) async {
                  playbackScopePaths = list
                      .map((s) => '${s['path'] ?? ''}')
                      .where((path) => path.isNotEmpty)
                      .toList();
                  _playingCollection = true;
                  try {
                    await playSong(song);
                  } finally {
                    _playingCollection = false;
                  }
                },
          artwork: artwork,
          onRemove: playlistName == null ? null : (path) => _removeSongFromPlaylist(playlistName, path),
          playlistName: playlistName,
          onPlayAll: playlistName == null ? null : () => _playCollection(list),
          onShuffleAll: playlistName == null ? null : () => _playCollection(list, shuffleOrder: true),
          onAddSongs: playlistName == null ? null : () => _addSongsToPlaylist(playlistName),
          onRenamePlaylist: playlistName == null ? null : () => _renamePlaylist(playlistName),
          onDeletePlaylist: playlistName == null ? null : () => _deletePlaylist(playlistName),
          onPlayNext: (path) => playNext(path), onQueue: (path) => addToQueue(path),
          onAddToPlaylist: (path) => addToPlaylist(path), onSongInfo: (song) => _showSongInfo(song),
          onAlbum: (song) async {
            _showSongListPage(
              '${song['album'] ?? 'Album'}',
              songs.where((s) => '${s['album']}' == '${song['album']}').toList(),
            );
          },
          onShare: (song) => _shareSong(song),
        ),
      ),
    );
  }

  Future<void> _removeSongFromPlaylist(String playlistName, String path) async {
    final list = playlists[playlistName];
    if (list == null) return;
    setState(() {
      list.remove(path);
      playlists[playlistName] = list;
    });
    await _saveData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song removed from playlist')),
      );
    }
  }

  void _showMoreMenu(BuildContext context) {

    showModalBottomSheet<void>(

      context: context,

      builder: (sheetContext) => SafeArea(

        child: Column(

          mainAxisSize: MainAxisSize.min,

          children: [

            ListTile(leading: const Icon(Icons.checklist), title: const Text('Multi-select'), onTap: () { Navigator.pop(sheetContext); _toggleMultiSelect(); }),

            ListTile(leading: const Icon(Icons.sort), title: const Text('Sort Order'), onTap: () { Navigator.pop(sheetContext); _showSortOrder(); }),

            ListTile(leading: const Icon(Icons.queue_music), title: const Text('Play queue'), onTap: () { Navigator.pop(sheetContext); _showQueue(); }),

            ListTile(leading: const Icon(Icons.refresh), title: const Text('Scan Music'), onTap: () { Navigator.pop(sheetContext); scanAll(); }),

            ListTile(leading: const Icon(Icons.favorite), title: const Text('Favorites'), onTap: () { Navigator.pop(sheetContext); selectSection('Favorites'); }),

            ListTile(leading: const Icon(Icons.history), title: const Text('Recent'), onTap: () { Navigator.pop(sheetContext); selectSection('Recents'); }),

          ],

        ),

      ),

    );

  }



  @override

  void dispose() {

    WidgetsBinding.instance.removeObserver(this);
    _savePlaybackState();
    player.dispose();

    super.dispose();

  }

}





class PlayingArtwork extends StatefulWidget {
  final Map<String, dynamic> song;
  final double size;
  final bool playing;
  final Widget Function(Map<String, dynamic>, {double size}) artwork;

  const PlayingArtwork({
    super.key,
    required this.song,
    required this.size,
    required this.playing,
    required this.artwork,
  });

  @override
  State<PlayingArtwork> createState() => _PlayingArtworkState();
}

class _PlayingArtworkState extends State<PlayingArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant PlayingArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final pulse = widget.playing
            ? 1.0 + (_controller.value < .5 ? _controller.value : 1 - _controller.value) * .035
            : 1.0;
        return Transform.scale(
          scale: pulse,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.playing ? Colors.deepOrangeAccent : Colors.transparent,
                width: 3,
              ),
              boxShadow: widget.playing
                  ? [
                      BoxShadow(
                        blurRadius: 16,
                        spreadRadius: 2,
                        color: Colors.deepOrange.withValues(alpha: .35),
                      ),
                    ]
                  : const [],
            ),
            child: child,
          ),
        );
      },
      child: ClipOval(child: widget.artwork(widget.song, size: widget.size)),
    );
  }
}

class NowPlayingPage extends StatefulWidget {

  final AudioPlayer player;

  final Map<String, dynamic> song;

  final List<Map<String, dynamic>> librarySongs;

  final bool Function(String path) isFavoriteFor;

  final bool isFavorite;

  final bool shuffle;

  final String repeatMode;

  final VoidCallback onFavorite;

  final VoidCallback onPrevious;

  final VoidCallback onNext;

  final ValueChanged<bool> onShuffle;

  final ValueChanged<String> onRepeatModeChanged;

  final VoidCallback onQueue;
  final VoidCallback onSortOrder;
  final VoidCallback onMultiSelect;



  const NowPlayingPage({

    super.key,

    required this.player,

    required this.song,

    required this.librarySongs,

    required this.isFavoriteFor,

    required this.isFavorite,

    required this.shuffle,

    required this.repeatMode,

    required this.onFavorite,

    required this.onPrevious,

    required this.onNext,

    required this.onShuffle,

    required this.onRepeatModeChanged,

    required this.onQueue,
    required this.onSortOrder,
    required this.onMultiSelect,

  });



  @override

  State<NowPlayingPage> createState() => _NowPlayingPageState();

}



class _NowPlayingPageState extends State<NowPlayingPage> {

  late bool _favorite;
  late bool _shuffle;
  late String _repeatMode;
  late Map<String, dynamic> _displaySong;
  StreamSubscription<int?>? _indexSubscription;

  @override
  void initState() {
    super.initState();
    _favorite = widget.isFavorite;
    _shuffle = widget.shuffle;
    _repeatMode = widget.repeatMode;
    _displaySong = Map<String, dynamic>.from(widget.song);

    _indexSubscription = widget.player.currentIndexStream.listen((_) {
      _syncDisplayedSong();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncDisplayedSong();
    });
  }

  void _syncDisplayedSong() {
    if (!mounted) return;

    final index = widget.player.currentIndex;
    final sequence = widget.player.sequence;

    if (index == null || index < 0 || index >= sequence.length) return;

    final tag = sequence[index].tag;
    final id = tag is MediaItem ? tag.id : '${tag?.id ?? ''}';

    Map<String, dynamic>? match;
    for (final candidate in widget.librarySongs) {
      if ('${candidate['uri'] ?? ''}' == id ||
          '${candidate['path'] ?? ''}' == id) {
        match = candidate;
        break;
      }
    }

    if (match == null && tag is MediaItem) {
      match = {
        ...widget.song,
        'title': tag.title,
        'artist': tag.artist ?? 'Unknown Artist',
        'album': tag.album ?? 'Unknown Album',
        'uri': tag.id,
      };
    }

    if (match != null && mounted) {
      final path = '${match['path'] ?? ''}';
      final wasFavorite = widget.isFavoriteFor(path);
      setState(() {
        _displaySong = Map<String, dynamic>.from(match!);
        _favorite = wasFavorite;
      });
    }
  }



  @override
  void dispose() {
    _indexSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = '${_displaySong['title'] ?? 'Unknown Song'}';
    final artist = '${_displaySong['artist'] ?? 'Unknown Artist'}';

    return Scaffold(

      backgroundColor: const Color(0xFF29251F),

      body: SafeArea(

        child: Column(

          children: [

            Padding(

              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),

              child: Row(

                children: [

                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down, size: 38)),

                  const Spacer(),

                  const Spacer(),

                  const Icon(Icons.music_note),

                ],

              ),

            ),

            Expanded(

              child: SingleChildScrollView(

                child: Column(

                  children: [

                    const SizedBox(height: 20),

                    StreamBuilder<bool>(
                      stream: widget.player.playingStream,
                      builder: (_, snapshot) => PlayingArtwork(
                        song: _displaySong,
                        size: MediaQuery.of(context).size.width * .78,
                        playing: snapshot.data == true,
                        artwork: (s, {double size = 56}) => _artwork(s, size: size),
                      ),
                    ),

                    const SizedBox(height: 25),

                    Padding(

                      padding: const EdgeInsets.symmetric(horizontal: 25),

                      child: Row(

                        children: [

                          Expanded(

                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

                              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),

                              const SizedBox(height: 5),

                              Text(artist, style: const TextStyle(fontSize: 22, color: Colors.white70)),

                            ]),

                          ),

                          IconButton(onPressed: () {
                            setState(() => _favorite = !_favorite);
                            widget.onFavorite();
                          }, icon: Icon(_favorite ? Icons.favorite : Icons.favorite_border, size: 38, color: _favorite ? Colors.red : Colors.white)),

                        ],

                      ),

                    ),

                  ],

                ),

              ),

            ),

            _buildControls(),

          ],

        ),

      ),

    );

  }



  Widget _artwork(Map<String, dynamic> song, {double? size}) {
    final path = '${song['albumArt'] ?? ''}';
    final actualSize = size ?? MediaQuery.of(context).size.width * .85;

    if (path.isNotEmpty && path != 'null') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Image.file(
          File(path),
          key: ValueKey(path),
          width: actualSize,
          height: actualSize,
          fit: BoxFit.cover,
          cacheWidth: (actualSize * MediaQuery.of(context).devicePixelRatio).round(),
          errorBuilder: (_, _, _) => Container(
            width: actualSize,
            height: actualSize,
            decoration: BoxDecoration(
              color: Colors.grey.shade800,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(Icons.music_note, size: actualSize * .28),
          ),
        ),
      );
    }

    return Container(
      width: actualSize,
      height: actualSize,
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Icon(Icons.music_note, size: actualSize * .28),
    );
  }



  Widget _buildControls() {

    return Padding(
      padding: const EdgeInsets.fromLTRB(25, 5, 25, 25),
      child: Column(
        children: [
          StreamBuilder<Duration?>(
            stream: widget.player.durationStream,
            builder: (_, durationSnapshot) {
              final duration = durationSnapshot.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: widget.player.positionStream,
                builder: (_, positionSnapshot) {
                  var position = positionSnapshot.data ?? Duration.zero;
                  if (position > duration) position = duration;
                  return Column(
                    children: [
                      Slider(
                        value: duration.inMilliseconds == 0 ? 0 : position.inMilliseconds.toDouble(),
                        max: duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds.toDouble(),
                        onChanged: (value) => widget.player.seek(Duration(milliseconds: value.toInt())),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [Text(_format(position)), Text(_format(duration))],
                      ),
                    ],
                  );
                },
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(onPressed: widget.onPrevious, icon: const Icon(Icons.skip_previous), iconSize: 45),
              const SizedBox(width: 28),
              StreamBuilder<bool>(
                stream: widget.player.playingStream,
                builder: (_, snapshot) {
                  final playing = snapshot.data == true;
                  return Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: IconButton(
                      onPressed: () => playing ? widget.player.pause() : widget.player.play(),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 45),
                    ),
                  );
                },
              ),
              const SizedBox(width: 28),
              IconButton(onPressed: widget.onNext, icon: const Icon(Icons.skip_next), iconSize: 45),
            ],
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: _showPlaybackOptions,
            icon: const Icon(Icons.tune),
            label: const Text('Playback Options'),
          ),
        ],
      ),
    );
  }

  void _showPlaybackOptions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text(
                  'Playback Options',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              SwitchListTile(
                secondary: Icon(_shuffle ? Icons.shuffle_on : Icons.shuffle),
                title: const Text('Shuffle'),
                subtitle: Text(_shuffle ? 'Shuffle is ON' : 'Shuffle is OFF'),
                value: _shuffle,
                onChanged: (value) {
                  setState(() => _shuffle = value);
                  widget.onShuffle(value);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.repeat),
                title: const Text('Repeat'),
                subtitle: Text(
                  _repeatMode == 'off'
                      ? 'Repeat Off'
                      : _repeatMode == 'one'
                          ? 'Repeat One'
                          : 'Repeat All',
                ),
                onTap: () {
                  final next = _repeatMode == 'off'
                      ? 'one'
                      : _repeatMode == 'one'
                          ? 'all'
                          : 'off';
                  setState(() => _repeatMode = next);
                  widget.onRepeatModeChanged(next);
                  Navigator.pop(sheetContext);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Play Queue'),
                subtitle: const Text('Open queue'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onQueue();
                },
              ),
              ListTile(
                leading: const Icon(Icons.sort),
                title: const Text('Sort Order'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onSortOrder();
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('Multi-select'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onMultiSelect();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String _format(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

}



class SongListPage extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(Map<String, dynamic>) onPlay;
  final Widget Function(Map<String, dynamic>, {double size}) artwork;
  final Future<void> Function(String path)? onRemove;
  final String? playlistName;
  final Future<void> Function()? onRenamePlaylist;
  final Future<void> Function()? onDeletePlaylist;
  final Future<void> Function()? onAddSongs;
  final Future<void> Function()? onPlayAll;
  final Future<void> Function()? onShuffleAll;
  final Future<void> Function(String path) onPlayNext;
  final Future<void> Function(String path) onQueue;
  final Future<void> Function(String path) onAddToPlaylist;
  final Future<void> Function(Map<String, dynamic> song) onSongInfo;
  final Future<void> Function(Map<String, dynamic> song) onAlbum;
  final Future<void> Function(Map<String, dynamic> song) onShare;
  const SongListPage({super.key, required this.title, required this.songs, required this.onPlay, required this.artwork, this.onRemove, this.playlistName, this.onRenamePlaylist, this.onDeletePlaylist, this.onAddSongs, this.onPlayAll, this.onShuffleAll, required this.onPlayNext, required this.onQueue, required this.onAddToPlaylist, required this.onSongInfo, required this.onAlbum, required this.onShare});
  @override State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  late List<Map<String, dynamic>> visibleSongs;
  @override void initState() { super.initState(); visibleSongs = List<Map<String, dynamic>>.from(widget.songs); }
  Future<void> _remove(Map<String, dynamic> song) async {
    final path = '${song['path'] ?? ''}';
    if (path.isEmpty || widget.onRemove == null) return;
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Remove from Playlist?'), content: Text('Remove "${song['title'] ?? 'this song'}" from this playlist?'), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove'))]));
    if (confirmed != true || !mounted) return;
    await widget.onRemove!(path);
    if (mounted) setState(() => visibleSongs.removeWhere((s) => '${s['path'] ?? ''}' == path));
  }
  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.playlistName == null ? const [] : [PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'play_all': await widget.onPlayAll?.call(); break;
              case 'shuffle': await widget.onShuffleAll?.call(); break;
              case 'add': await widget.onAddSongs?.call(); break;
              case 'rename': await widget.onRenamePlaylist?.call(); break;
              case 'delete': await widget.onDeletePlaylist?.call(); if (context.mounted) Navigator.pop(context); break;
            }
          },
          itemBuilder: (_) => const [PopupMenuItem(value: 'play_all', child: Text('Play All')), PopupMenuItem(value: 'shuffle', child: Text('Shuffle')), PopupMenuItem(value: 'add', child: Text('Add Songs')), PopupMenuItem(value: 'rename', child: Text('Rename Playlist')), PopupMenuItem(value: 'delete', child: Text('Delete Playlist'))],
        )],
      ),
      body: visibleSongs.isEmpty ? const Center(child: Text('No songs in this playlist')) : ListView.builder(
        itemCount: visibleSongs.length,
        itemBuilder: (_, index) {
          final song = visibleSongs[index];
          final path = '${song['path'] ?? ''}';
          return ListTile(
            leading: widget.artwork(song), title: Text('${song['title'] ?? 'Unknown Song'}'), subtitle: Text('${song['artist'] ?? 'Unknown Artist'}'), onTap: () => widget.onPlay(song),
            trailing: PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'play_next': await widget.onPlayNext(path); break;
                  case 'queue': await widget.onQueue(path); break;
                  case 'playlist': await widget.onAddToPlaylist(path); break;
                  case 'info': await widget.onSongInfo(song); break;
                  case 'album': await widget.onAlbum(song); break;
                  case 'share': await widget.onShare(song); break;
                  case 'remove': await _remove(song); break;
                }
              },
              itemBuilder: (_) => [const PopupMenuItem(value: 'play_next', child: Text('Play next')), const PopupMenuItem(value: 'queue', child: Text('Add to queue')), const PopupMenuItem(value: 'playlist', child: Text('Add to another playlist')), const PopupMenuItem(value: 'info', child: Text('Song Info')), const PopupMenuItem(value: 'album', child: Text('Album')), const PopupMenuItem(value: 'share', child: Text('Share')), if (widget.onRemove != null) const PopupMenuItem(value: 'remove', child: Text('Remove from this playlist'))],
            ),
          );
        },
      ),
    );
  }
}


class VideoPage extends StatefulWidget {

  final String path;

  final String title;

  const VideoPage({super.key, required this.path, required this.title});

  @override

  State<VideoPage> createState() => _VideoPageState();

}



class _VideoPageState extends State<VideoPage> {

  VideoPlayerController? controller;



  @override

  void initState() {

    super.initState();

    controller = VideoPlayerController.file(File(widget.path))

      ..initialize().then((_) {

        if (mounted) setState(() {});

      });

  }



  @override

  Widget build(BuildContext context) {

    final c = controller;

    return Scaffold(

      appBar: AppBar(title: Text(widget.title)),

      body: c == null || !c.value.isInitialized

          ? const Center(child: CircularProgressIndicator())

          : Center(

              child: AspectRatio(

                aspectRatio: c.value.aspectRatio,

                child: Stack(alignment: Alignment.bottomCenter, children: [

                  VideoPlayer(c),

                  VideoProgressIndicator(c, allowScrubbing: true),

                  Center(child: IconButton(iconSize: 64, icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow), onPressed: () => setState(() => c.value.isPlaying ? c.pause() : c.play()))),

                ]),

              ),

            ),

    );

  }



  @override

  void dispose() {

    controller?.dispose();

    super.dispose();

  }

}



class MusicSearchDelegate extends SearchDelegate<Map<String, dynamic>?> {

  final List<Map<String, dynamic>> songs;

  final Future<void> Function(Map<String, dynamic>) onPlay;

  final Widget Function(Map<String, dynamic>, {double size}) artwork;



  MusicSearchDelegate({required this.songs, required this.onPlay, required this.artwork});



  @override

  List<Widget>? buildActions(BuildContext context) => [IconButton(onPressed: () => query = '', icon: const Icon(Icons.clear))];

  @override

  Widget? buildLeading(BuildContext context) => IconButton(onPressed: () => close(context, null), icon: const Icon(Icons.arrow_back));



  List<Map<String, dynamic>> get matches {

    final q = query.toLowerCase().trim();

    if (q.isEmpty) return songs;

    return songs.where((s) {

      return '${s['title'] ?? ''}'.toLowerCase().contains(q) ||

          '${s['artist'] ?? ''}'.toLowerCase().contains(q) ||

          '${s['album'] ?? ''}'.toLowerCase().contains(q) ||

          '${s['folder'] ?? ''}'.toLowerCase().contains(q);

    }).toList();

  }



  @override

  Widget buildResults(BuildContext context) => _results();

  @override

  Widget buildSuggestions(BuildContext context) => _results();



  Widget _results() {

    return ListView.builder(

      itemCount: matches.length,

      itemBuilder: (context, index) {

        final song = matches[index];

        return ListTile(

          leading: artwork(song),

          title: Text('${song['title'] ?? 'Unknown Song'}'),

          subtitle: Text('${song['artist'] ?? 'Unknown Artist'}'),

          onTap: () async {

            await onPlay(song);

            if (context.mounted) close(context, song);

          },

        );

      },

    );

  }

}
