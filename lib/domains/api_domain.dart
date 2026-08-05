import 'dart:io';

import 'package:roll_feathers/domains/die_domain.dart';
import 'package:roll_feathers/domains/roll_domain.dart';
import 'package:roll_feathers/dice_sdks/dice_sdks.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_routing/shelf_routing.dart';

abstract class ApiDomain {
  List<String> getIpAddresses();
}

class EmptyApiDomain extends ApiDomain {
  @override
  List<String> getIpAddresses() => [];
}

Handler buildApiHandler(RollDomain rollDomain, DieDomain dieDomain) {
  final router = Router();

  Map<String, dynamic> dieJson(GenericDie die) {
    final isVirtual = die.type == GenericDieType.virtual;

    return {
      'id': die.dieId,
      'name': die.friendlyName,
      'kind': isVirtual ? 'virtual' : 'physical',
      'dieType': die.type.name,
      'denomination': 'd${die.dType.faceCount}',
      'faces': die.dType.faceCount,
      'connected': true,
    };
  }

  Map<String, dynamic> singleRollJson(
    RollResult result,
    String dieId,
    int value,
    int index,
  ) {
    final die = dieDomain.getDieById(dieId);
    final isVirtual = die?.type == GenericDieType.virtual;

    // A deterministic, monotonic-enough identifier per die event.
    final base = result.rollTime.microsecondsSinceEpoch;

    return {
      'eventId': base * 1000 + index,
      'timestamp': result.rollTime.toIso8601String(),
      'dieId': dieId,
      'name': die?.friendlyName,
      'kind': isVirtual ? 'virtual' : 'physical',
      'dieType': die?.type.name,
      'denomination': die == null ? null : 'd${die.dType.faceCount}',
      'faces': die?.dType.faceCount,
      'value': value,
    };
  }

  List<Map<String, dynamic>> explodeRoll(RollResult result) {
    final events = <Map<String, dynamic>>[];
    var index = 0;

    result.rolls.forEach((dieId, value) {
      events.add(singleRollJson(result, dieId, value, index));
      index += 1;
    });

    return events;
  }

  router.get('/api/last-roll', (Request request) {
    final result = rollDomain.rollHistory.firstOrNull;
    if (result == null) return Response.notFound(null);

    return JsonResponse.ok({
      ...result.toJson(),
      'events': explodeRoll(result),
    });
  });

  router.get('/api/dice', (Request request) {
    final dice = dieDomain.dice.values.map(dieJson).toList();

    return JsonResponse.ok({
      'revision': DateTime.now().microsecondsSinceEpoch,
      'dice': dice,
    });
  });

  router.get('/api/rolls', (Request request) {
    final after =
        int.tryParse(request.url.queryParameters['after'] ?? '0') ?? 0;
    final requestedLimit =
        int.tryParse(request.url.queryParameters['limit'] ?? '100') ?? 100;
    final limit = requestedLimit.clamp(1, 500);

    final events = <Map<String, dynamic>>[];

    // rollHistory is newest-first in current Roll Feathers.
    for (final result in rollDomain.rollHistory.reversed) {
      for (final event in explodeRoll(result)) {
        if ((event['eventId'] as int) > after) {
          events.add(event);
        }
      }
    }

    final selected = events.take(limit).toList();
    final latestEventId = events.isEmpty
        ? after
        : events
            .map((event) => event['eventId'] as int)
            .reduce((a, b) => a > b ? a : b);

    return JsonResponse.ok({
      'latestEventId': latestEventId,
      'rolls': selected,
    });
  });

  final handler = const Pipeline()
      .addMiddleware((inner) {
        return (request) async {
          if (request.method == 'OPTIONS') {
            return Response.ok('', headers: {
              'Access-Control-Allow-Origin': '*',
              'Access-Control-Allow-Headers': 'Content-Type',
              'Access-Control-Allow-Methods': 'GET, OPTIONS',
            });
          }

          final response = await inner(request);
          return response.change(headers: {
            ...response.headers,
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Allow-Methods': 'GET, OPTIONS',
          });
        };
      })
      .addMiddleware(logRequests())
      .addHandler(router.call);

  return handler;
}

class ApiDomainServer extends ApiDomain {
  final List<NetworkInterface> _networkInterfaces;

  ApiDomainServer._(this._networkInterfaces);

  static Future<ApiDomain> create({
    required RollDomain rollDomain,
    required DieDomain dieDomain,
    int port = 8080,
  }) async {
    List<NetworkInterface> interfaces = [];

    try {
      interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
    } on Exception catch (_) {}

    try {
      await shelf_io.serve(
        buildApiHandler(rollDomain, dieDomain),
        InternetAddress.anyIPv4,
        port,
      );
    } on SocketException {
      return EmptyApiDomain();
    }

    return ApiDomainServer._(interfaces);
  }

  @override
  List<String> getIpAddresses() => _networkInterfaces
      .expand((interface) => interface.addresses)
      .map((address) => address.address)
      .toList();
}
