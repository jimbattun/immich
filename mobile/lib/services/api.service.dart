import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

class ApiService implements Authentication {
  late ApiClient _apiClient;

  late UsersApi usersApi;
  late AuthenticationApi authenticationApi;
  late OAuthApi oAuthApi;
  late AlbumsApi albumsApi;
  late AssetsApi assetsApi;
  late SearchApi searchApi;
  late ServerApi serverInfoApi;
  late MapApi mapApi;
  late PartnersApi partnersApi;
  late PeopleApi peopleApi;
  late SharedLinksApi sharedLinksApi;
  late SyncApi syncApi;
  late SystemConfigApi systemConfigApi;
  late ActivitiesApi activitiesApi;
  late DownloadApi downloadApi;
  late TrashApi trashApi;
  late StacksApi stacksApi;
  late ViewApi viewApi;
  late MemoriesApi memoriesApi;

  ApiService() {
    // Попытка получить сохранённый endpoint из локального Store.
    final endpoint = Store.tryGet(StoreKey.serverEndpoint) ?? "";
    if (endpoint.isNotEmpty) {
      setEndpoint(endpoint);
    } else {
      // Если данные отсутствуют, задаём жёсткий URL и сохраняем его.
      const defaultUrl = "https://api.myclick.app";
      // Если сервер требует обращения к "/api", resolveEndpoint добавит его
      setEndpoint(defaultUrl);
      Store.put(StoreKey.serverEndpoint, defaultUrl);
    }
  }

  String? _accessToken;
  final _log = Logger("ApiService");

  void setEndpoint(String endpoint) {
    _apiClient = ApiClient(basePath: endpoint, authentication: this);
    if (_accessToken != null) {
      setAccessToken(_accessToken!);
    }
    usersApi = UsersApi(_apiClient);
    authenticationApi = AuthenticationApi(_apiClient);
    oAuthApi = OAuthApi(_apiClient);
    albumsApi = AlbumsApi(_apiClient);
    assetsApi = AssetsApi(_apiClient);
    serverInfoApi = ServerApi(_apiClient);
    searchApi = SearchApi(_apiClient);
    mapApi = MapApi(_apiClient);
    partnersApi = PartnersApi(_apiClient);
    peopleApi = PeopleApi(_apiClient);
    sharedLinksApi = SharedLinksApi(_apiClient);
    syncApi = SyncApi(_apiClient);
    systemConfigApi = SystemConfigApi(_apiClient);
    activitiesApi = ActivitiesApi(_apiClient);
    downloadApi = DownloadApi(_apiClient);
    trashApi = TrashApi(_apiClient);
    stacksApi = StacksApi(_apiClient);
    viewApi = ViewApi(_apiClient);
    memoriesApi = MemoriesApi(_apiClient);
  }

  Future<String> resolveAndSetEndpoint(String serverUrl) async {
    final endpoint = await resolveEndpoint(serverUrl);
    setEndpoint(endpoint);
    // Сохраняем endpoint для будущих запусков
    Store.put(StoreKey.serverEndpoint, endpoint);
    return endpoint;
  }

  /// Принимает серверный URL и пытается определить конечную точку API.
  Future<String> resolveEndpoint(String serverUrl) async {
    String url = sanitizeUrl(serverUrl);

    // Проверка наличия файла /.well-known/immich
    final wellKnownEndpoint = await _getWellKnownEndpoint(url);
    if (wellKnownEndpoint.isNotEmpty) {
      url = sanitizeUrl(wellKnownEndpoint);
    }

    if (!await _isEndpointAvailable(url)) {
      throw ApiException(503, "Server is not reachable");
    }

    return url;
  }

  Future<bool> _isEndpointAvailable(String serverUrl) async {
    String apiUrl = serverUrl;
    // Если URL не заканчивается на "/api", добавляем его
    if (!apiUrl.endsWith('/api')) {
      apiUrl += '/api';
    }

    try {
      // Убираем await, т.к. setEndpoint возвращает void
      setEndpoint(apiUrl);
      await serverInfoApi.pingServer().timeout(const Duration(seconds: 5));
    } on TimeoutException catch (_) {
      return false;
    } on SocketException catch (_) {
      return false;
    } catch (error, stackTrace) {
      _log.severe(
        "Error while checking server availability",
        error,
        stackTrace,
      );
      return false;
    }
    return true;
  }

  Future<String> _getWellKnownEndpoint(String baseUrl) async {
    final Client client = Client();

    try {
      final headers = {"Accept": "application/json"}..addAll(getRequestHeaders());

      final res = await client
          .get(Uri.parse("$baseUrl/.well-known/immich"), headers: headers)
          .timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final endpoint = data['api']['endpoint'].toString();

        if (endpoint.startsWith('/')) {
          return "$baseUrl$endpoint";
        }
        return endpoint;
      }
    } catch (e) {
      debugPrint("Could not locate /.well-known/immich at $baseUrl");
    }

    return "";
  }

  Future<void> setAccessToken(String accessToken) async {
    _accessToken = accessToken;
    await Store.put(StoreKey.accessToken, accessToken);
  }

  Future<void> setDeviceInfoHeader() async {
    final deviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isIOS) {
      final iosInfo = await deviceInfoPlugin.iosInfo;
      authenticationApi.apiClient
          .addDefaultHeader('deviceModel', iosInfo.utsname.machine);
      authenticationApi.apiClient.addDefaultHeader('deviceType', 'iOS');
    } else {
      final androidInfo = await deviceInfoPlugin.androidInfo;
      authenticationApi.apiClient
          .addDefaultHeader('deviceModel', androidInfo.model);
      authenticationApi.apiClient.addDefaultHeader('deviceType', 'Android');
    }
  }

  static Map<String, String> getRequestHeaders() {
    final accessToken = Store.get(StoreKey.accessToken, "");
    final customHeadersStr = Store.get(StoreKey.customHeaders, "");
    final header = <String, String>{};
    if (accessToken.isNotEmpty) {
      header['x-immich-user-token'] = accessToken;
    }
    if (customHeadersStr.isNotEmpty) {
      final customHeaders = jsonDecode(customHeadersStr) as Map;
      customHeaders.forEach((key, value) {
        header[key] = value;
      });
    }
    return header;
  }

  @override
  Future<void> applyToParams(
      List<QueryParam> queryParams, Map<String, String> headerParams) {
    return Future<void>(() {
      final headers = ApiService.getRequestHeaders();
      headerParams.addAll(headers);
    });
  }

  ApiClient get apiClient => _apiClient;
}
