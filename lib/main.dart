import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

void main() => runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFFCC00), brightness: Brightness.dark)),
    home: const Home()));

class Dev {
  final String name, avt, rc;
  Dev(this.name, this.avt, this.rc);
}

Future<List<Dev>> discover() async {
  final locs = <String>{};
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sock.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = sock.receive();
    if (d == null) return;
    final m = RegExp(r'location:\s*(\S+)', caseSensitive: false)
        .firstMatch(utf8.decode(d.data, allowMalformed: true));
    if (m != null) locs.add(m.group(1)!);
  });
  final msg = utf8.encode('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\nMX: 2\r\n'
      'ST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n');
  for (var i = 0; i < 3; i++) {
    sock.send(msg, InternetAddress('239.255.255.250'), 1900);
    await Future.delayed(const Duration(seconds: 1));
  }
  await Future.delayed(const Duration(seconds: 1));
  sock.close();
  final out = <Dev>[];
  for (final l in locs) {
    try {
      final xml = (await http.get(Uri.parse(l)).timeout(const Duration(seconds: 3))).body;
      String? ctl(String t) => RegExp(
              '<service>(?:(?!</service>)[\\s\\S])*?$t(?:(?!</service>)[\\s\\S])*?<controlURL>(.*?)</controlURL>')
          .firstMatch(xml)
          ?.group(1);
      final a = ctl('AVTransport');
      if (a == null) continue;
      final r = ctl('RenderingControl');
      final name = RegExp(r'<friendlyName>(.*?)</friendlyName>').firstMatch(xml)?.group(1) ?? l;
      final base = Uri.parse(l);
      out.add(Dev(name, base.resolve(a).toString(), r == null ? '' : base.resolve(r).toString()));
    } catch (_) {}
  }
  return out;
}

Future<void> soap(String url, String svc, String act, String args) async {
  if (url.isEmpty) return;
  await http.post(Uri.parse(url), headers: {
    'Content-Type': 'text/xml; charset="utf-8"',
    'SOAPACTION': '"urn:schemas-upnp-org:service:$svc:1#$act"'
  }, body: '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      '<u:$act xmlns:u="urn:schemas-upnp-org:service:$svc:1">$args</u:$act></s:Body></s:Envelope>');
}

String esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String mimeOf(String p) {
  final e = p.split('.').last.toLowerCase();
  return const {'mp3': 'audio/mpeg', 'flac': 'audio/flac', 'wav': 'audio/wav', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'ogg': 'audio/ogg'}[e] ?? 'audio/mpeg';
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final tracks = <PlatformFile>[];
  final player = AudioPlayer();
  HttpServer? srv;
  Dev? dev;
  int idx = -1;
  bool playing = false;

  @override
  void initState() {
    super.initState();
    startServer();
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed && dev == null) next();
    });
  }

  Future<void> startServer() async {
    srv = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
    srv!.listen((r) async {
      try {
        final i = int.parse(r.uri.pathSegments.first.split('.').first);
        final f = File(tracks[i].path!);
        final len = await f.length();
        var s = 0, e = len - 1;
        final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(r.headers.value('range') ?? '');
        if (m != null) {
          if (m[1]!.isNotEmpty) s = int.parse(m[1]!);
          if (m[2]!.isNotEmpty) e = int.parse(m[2]!);
          r.response.statusCode = 206;
          r.response.headers.set('Content-Range', 'bytes $s-$e/$len');
        }
        r.response.headers
          ..set('Content-Type', mimeOf(f.path))
          ..set('Accept-Ranges', 'bytes')
          ..set('transferMode.dlna.org', 'Streaming');
        r.response.contentLength = e - s + 1;
        if (r.method != 'HEAD') await r.response.addStream(f.openRead(s, e + 1));
        await r.response.close();
      } catch (_) {
        try { r.response.statusCode = 404; await r.response.close(); } catch (_) {}
      }
    });
  }

  Future<String> localIp() async {
    for (final n in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in n.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
    return '127.0.0.1';
  }

  String title(int i) => tracks[i].name.replaceFirst(RegExp(r'\.[^.]+$'), '');

  Future<void> pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
    if (r == null) return;
    setState(() => tracks.addAll(r.files.where((f) => f.path != null)));
  }

  Future<void> play(int i) async {
    if (i < 0 || i >= tracks.length) return;
    setState(() { idx = i; playing = true; });
    try {
      if (dev == null) {
        await player.setFilePath(tracks[i].path!);
        player.play();
      } else {
        await player.pause();
        final url = 'http://${await localIp()}:8765/$i.${tracks[i].name.split('.').last}';
        final didl = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
            '<item id="0" parentID="-1" restricted="1"><dc:title>${esc(title(i))}</dc:title>'
            '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
            '<res protocolInfo="http-get:*:${mimeOf(tracks[i].path!)}:*">$url</res></item></DIDL-Lite>';
        await soap(dev!.avt, 'AVTransport', 'SetAVTransportURI',
            '<InstanceID>0</InstanceID><CurrentURI>$url</CurrentURI><CurrentURIMetaData>${esc(didl)}</CurrentURIMetaData>');
        await soap(dev!.avt, 'AVTransport', 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> toggle() async {
    if (idx < 0) return tracks.isEmpty ? null : play(0);
    if (playing) {
      dev == null ? await player.pause() : await soap(dev!.avt, 'AVTransport', 'Pause', '<InstanceID>0</InstanceID>');
    } else {
      dev == null ? player.play() : await soap(dev!.avt, 'AVTransport', 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
    }
    setState(() => playing = !playing);
  }

  void next() => play(idx + 1);

  void devices() {
    showModalBottomSheet(
        context: context,
        builder: (c) => StatefulBuilder(builder: (c, set) {
              return FutureBuilder<List<Dev>>(
                  future: discover(),
                  builder: (c, s) => ListView(padding: const EdgeInsets.all(8), children: [
                        const ListTile(title: Text('Устройства', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                        ListTile(
                            leading: const Icon(Icons.phone_android),
                            title: const Text('Этот телефон'),
                            selected: dev == null,
                            onTap: () { Navigator.pop(c); switchTo(null); }),
                        if (!s.hasData) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
                        for (final d in s.data ?? <Dev>[])
                          ListTile(
                              leading: const Icon(Icons.speaker),
                              title: Text(d.name),
                              selected: dev?.avt == d.avt,
                              onTap: () { Navigator.pop(c); switchTo(d); }),
                        if (s.hasData && s.data!.isEmpty)
                          const ListTile(title: Text('Ничего не найдено. Проверь, что телефон и усилитель в одной Wi-Fi сети.')),
                        if (dev != null && dev!.rc.isNotEmpty)
                          VolSlider(dev: dev!),
                      ]));
            }));
  }

  Future<void> switchTo(Dev? d) async {
    final was = playing, i = idx;
    if (dev != null) { try { await soap(dev!.avt, 'AVTransport', 'Stop', '<InstanceID>0</InstanceID>'); } catch (_) {} }
    await player.pause();
    setState(() => dev = d);
    if (was && i >= 0) play(i);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('WiCast'), actions: [
        IconButton(icon: const Icon(Icons.library_add), onPressed: pick),
        IconButton(icon: Icon(dev == null ? Icons.cast : Icons.cast_connected, color: dev == null ? null : cs.primary), onPressed: devices),
      ]),
      body: tracks.isEmpty
          ? const Center(child: Text('Нажми + и добавь музыку'))
          : ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (c, i) => ListTile(
                  leading: Icon(i == idx ? Icons.graphic_eq : Icons.music_note, color: i == idx ? cs.primary : null),
                  title: Text(title(i), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => play(i))),
      bottomNavigationBar: idx < 0
          ? null
          : Material(
              color: cs.surfaceContainerHigh,
              child: SafeArea(
                  child: ListTile(
                title: Text(title(idx), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(dev?.name ?? 'Этот телефон'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.skip_previous), onPressed: () => play(idx - 1)),
                  IconButton(icon: Icon(playing ? Icons.pause_circle : Icons.play_circle, size: 40), onPressed: toggle),
                  IconButton(icon: const Icon(Icons.skip_next), onPressed: next),
                ]),
              ))),
    );
  }
}

class VolSlider extends StatefulWidget {
  final Dev dev;
  const VolSlider({super.key, required this.dev});
  @override
  State<VolSlider> createState() => _VolSliderState();
}

class _VolSliderState extends State<VolSlider> {
  double v = 30;
  @override
  Widget build(BuildContext c) => ListTile(
      leading: const Icon(Icons.volume_up),
      title: Slider(
          value: v, min: 0, max: 100,
          onChanged: (x) => setState(() => v = x),
          onChangeEnd: (x) => soap(widget.dev.rc, 'RenderingControl', 'SetVolume',
              '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>${x.round()}</DesiredVolume>')));
}
