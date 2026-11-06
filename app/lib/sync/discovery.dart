import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

import 'hub_server.dart';

/// Announces the hub on the local network (Bonjour / mDNS) so phones can
/// find it even when the PC's IP address changes.
class HubAdvertiser {
  BonsoirBroadcast? _broadcast;

  Future<void> start(String hubId, String name, int port) async {
    await stop();
    try {
      final service = BonsoirService(
        name: 'Cabinet CRM ($name)',
        type: serviceType,
        port: port,
        attributes: {'hub': hubId},
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.initialize();
      await _broadcast!.start();
    } catch (_) {
      // Discovery is a convenience; pairing by QR still works without it.
      _broadcast = null;
    }
  }

  Future<void> stop() async {
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
  }
}

/// A main office PC found on the network.
class FoundHub {
  FoundHub(this.hubId, this.name, this.hosts);
  final String hubId, name;

  /// "host:port" candidates, IPv4 first.
  final List<String> hosts;
}

/// Look for main office PCs on the local network for a few seconds.
Future<List<FoundHub>> findHubs({Duration timeout = const Duration(seconds: 4)}) async {
  final found = <String, FoundHub>{};
  BonsoirDiscovery? discovery;
  try {
    discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    final sub = discovery.eventStream?.listen((event) {
      final service = event.service;
      if (service == null) return;
      if (event is BonsoirDiscoveryServiceFoundEvent) {
        service.resolve(discovery!.serviceResolver);
      } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
        final id = service.attributes['hub'];
        if (id == null) return;
        // Prefer IPv4 addresses; IPv6 needs brackets in a URL.
        final addrs = [...service.hostAddresses]..sort((a, b) => a.contains(':') ? 1 : (b.contains(':') ? -1 : 0));
        final hosts = [
          for (final a in addrs) a.contains(':') ? '[$a]:${service.port}' : '$a:${service.port}',
          if (service.hostname != null) '${service.hostname}:${service.port}',
        ];
        final name = service.name.replaceFirst('Cabinet CRM (', '').replaceFirst(RegExp(r'\)$'), '');
        found[id] = FoundHub(id, name, {...?found[id]?.hosts, ...hosts}.toList());
      }
    });
    await discovery.start();
    await Future<void>.delayed(timeout);
    await sub?.cancel();
  } catch (_) {
    // Discovery not available on this network / platform: typing the address still works.
  } finally {
    try {
      await discovery?.stop();
    } catch (_) {}
  }
  return found.values.toList();
}

/// Look for the hub with [hubId]. Returns "host:port" list.
Future<List<String>> discoverHub(String hubId, {Duration timeout = const Duration(seconds: 4)}) async {
  final hubs = await findHubs(timeout: timeout);
  return [for (final h in hubs) if (h.hubId == hubId) ...h.hosts];
}
