import 'dart:io';
import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/oauth.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/utils/provider_utils.dart';
import 'package:immich_mobile/utils/version_compatibility.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:immich_mobile/widgets/common/immich_title_text.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:immich_mobile/widgets/forms/login/email_input.dart';
import 'package:immich_mobile/widgets/forms/login/loading_icon.dart';
import 'package:immich_mobile/widgets/forms/login/login_button.dart';
import 'package:immich_mobile/widgets/forms/login/o_auth_login_button.dart';
import 'package:immich_mobile/widgets/forms/login/password_input.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class LoginForm extends HookConsumerWidget {
  LoginForm({super.key});

  final log = Logger('LoginForm');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emailController =
        useTextEditingController.fromValue(TextEditingValue.empty);
    final passwordController =
        useTextEditingController.fromValue(TextEditingValue.empty);
    // Контроллер для серверного URL – теперь он задаётся жёстко
    final serverEndpointController =
        useTextEditingController.fromValue(TextEditingValue.empty);
    final emailFocusNode = useFocusNode();
    final passwordFocusNode = useFocusNode();
    final isLoading = useState<bool>(false);
    final isLoadingServer = useState<bool>(false);
    final isOauthEnable = useState<bool>(false);
    final isPasswordLoginEnable = useState<bool>(false);
    final oAuthButtonLabel = useState<String>('OAuth');
    final logoAnimationController = useAnimationController(
      duration: const Duration(seconds: 60),
    )..repeat();
    final serverInfo = ref.watch(serverInfoProvider);
    final warningMessage = useState<String?>(null);
    final loginFormKey = GlobalKey<FormState>();
    // Значение серверного URL хранится здесь (после валидации)
    final ValueNotifier<String?> serverEndpoint = useState<String?>(null);

    // Проверка совместимости версий приложения и сервера
    Future<void> checkVersionMismatch() async {
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        final appVersion = packageInfo.version;
        final appMajorVersion = int.parse(appVersion.split('.')[0]);
        final appMinorVersion = int.parse(appVersion.split('.')[1]);
        final serverMajorVersion = serverInfo.serverVersion.major;
        final serverMinorVersion = serverInfo.serverVersion.minor;

        warningMessage.value = getVersionCompatibilityMessage(
          appMajorVersion,
          appMinorVersion,
          serverMajorVersion,
          serverMinorVersion,
        );
      } catch (error) {
        warningMessage.value = 'Error checking version compatibility';
      }
    }

    /// Получение настроек авторизации сервера с использованием хардкоденного URL
    Future<void> getServerAuthSettings() async {
      // Задаём жёсткий URL сервера (без "/api" – он будет добавлен при валидации)
      final serverUrl = "https://api.myclick.app";

      try {
        isLoadingServer.value = true;
        // Функция validateServerUrl должна возвращать конечный URL (например, с "/api")
        final endpoint =
            await ref.read(authProvider.notifier).validateServerUrl(serverUrl);

        // Загружаем конфигурацию сервера и его возможности
        await ref.read(serverInfoProvider.notifier).getServerInfo();

        final serverInfo = ref.read(serverInfoProvider);
        final features = serverInfo.serverFeatures;
        final config = serverInfo.serverConfig;

        isOauthEnable.value = features.oauthEnabled;
        isPasswordLoginEnable.value = features.passwordLogin;
        oAuthButtonLabel.value = config.oauthButtonText.isNotEmpty
            ? config.oauthButtonText
            : 'OAuth';

        serverEndpoint.value = endpoint;
      } on ApiException catch (e) {
        ImmichToast.show(
          context: context,
          msg: e.message ?? 'login_form_api_exception'.tr(),
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isOauthEnable.value = false;
        isPasswordLoginEnable.value = true;
      } on HandshakeException {
        ImmichToast.show(
          context: context,
          msg: 'login_form_handshake_exception'.tr(),
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isOauthEnable.value = false;
        isPasswordLoginEnable.value = true;
      } catch (e) {
        ImmichToast.show(
          context: context,
          msg: 'login_form_server_error'.tr(),
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isOauthEnable.value = false;
        isPasswordLoginEnable.value = true;
      } finally {
        isLoadingServer.value = false;
      }
    }

    // При первом построении виджета сразу задаём жесткий URL и вызываем конфигурацию сервера
    useEffect(() {
      const hardcodedServerUrl = "https://api.myclick.app";
      serverEndpointController.text = hardcodedServerUrl;
      serverEndpoint.value = hardcodedServerUrl;
      getServerAuthSettings();
      return null;
    }, []);

    // Функции для тестового заполнения (опционально)
    void populateTestLoginInfo() {
      emailController.text = 'demo@immich.app';
      passwordController.text = 'demo';
    }

    void populateTestLoginInfo1() {
      emailController.text = 'testuser@email.com';
      passwordController.text = 'password';
    }

    Future<void> login() async {
      TextInput.finishAutofillContext();
      isLoading.value = true;

      // Сброс кеша провайдеров API для учёта нового токена
      invalidateAllApiRepositoryProviders(ref);

      try {
        final result = await ref.read(authProvider.notifier).login(
              emailController.text,
              passwordController.text,
            );

        if (result.shouldChangePassword && !result.isAdmin) {
          context.pushRoute(const ChangePasswordRoute());
        } else {
          context.replaceRoute(const TabControllerRoute());
        }
      } catch (error) {
        ImmichToast.show(
          context: context,
          msg: "login_form_failed_login".tr(),
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
      } finally {
        isLoading.value = false;
      }
    }

    Future<void> oAuthLogin() async {
      final oAuthService = ref.watch(oAuthServiceProvider);
      String? oAuthServerUrl;

      try {
        oAuthServerUrl =
            await oAuthService.getOAuthServerUrl("https://api.myclick.app");
        isLoading.value = true;
      } catch (error, stack) {
        log.severe('Error getting OAuth server Url: $error', stack);
        ImmichToast.show(
          context: context,
          msg: "login_form_failed_get_oauth_server_config".tr(),
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isLoading.value = false;
        return;
      }

      if (oAuthServerUrl != null) {
        try {
          final loginResponseDto = await oAuthService.oAuthLogin(oAuthServerUrl);
          if (loginResponseDto == null) return;

          log.info(
              "Finished OAuth login with response: ${loginResponseDto.userEmail}");
          final isSuccess = await ref
              .watch(authProvider.notifier)
              .saveAuthInfo(accessToken: loginResponseDto.accessToken);

          if (isSuccess) {
            final permission = ref.watch(galleryPermissionNotifier);
            if (permission.isGranted || permission.isLimited) {
              ref.watch(backupProvider.notifier).resumeBackup();
            }
            context.replaceRoute(const TabControllerRoute());
          }
        } catch (error, stack) {
          log.severe('Error logging in with OAuth: $error', stack);
          ImmichToast.show(
            context: context,
            msg: error.toString(),
            toastType: ToastType.error,
            gravity: ToastGravity.TOP,
          );
        } finally {
          isLoading.value = false;
        }
      } else {
        ImmichToast.show(
          context: context,
          msg: "login_form_failed_get_oauth_server_disable".tr(),
          toastType: ToastType.info,
          gravity: ToastGravity.TOP,
        );
        isLoading.value = false;
      }
    }

    // Форма логина (без экрана выбора сервера)
    Widget buildLogin() {
      return AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildVersionCompatWarning(),
          //  Text(
          //    "https://api.myclick.app",
          //    style: context.textTheme.displaySmall,
          //    textAlign: TextAlign.center,
         //   ),
            if (isPasswordLoginEnable.value) ...[
              const SizedBox(height: 18),
              EmailInput(
                controller: emailController,
                focusNode: emailFocusNode,
                onSubmit: passwordFocusNode.requestFocus,
              ),
              const SizedBox(height: 8),
              PasswordInput(
                controller: passwordController,
                focusNode: passwordFocusNode,
                onSubmit: login,
              ),
            ],
            isLoading.value
                ? const LoadingIcon()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 18),
                      if (isPasswordLoginEnable.value)
                        LoginButton(onPressed: login),
                      if (isOauthEnable.value) ...[
                        if (isPasswordLoginEnable.value)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16.0),
                            child: Divider(
                              color: context.isDarkTheme
                                  ? Colors.white
                                  : Colors.black,
                            ),
                          ),
                        OAuthLoginButton(
                          serverEndpointController: serverEndpointController,
                          buttonLabel: oAuthButtonLabel.value,
                          isLoading: isLoading,
                          onPressed: oAuthLogin,
                        ),
                      ],
                    ],
                  ),
          ],
        ),
      );
    }

    // Всегда отображаем форму логина
    final loginWidget = buildLogin();

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: constraints.maxHeight / 5),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onDoubleTap: populateTestLoginInfo,
                        onLongPress: populateTestLoginInfo1,
                        child: RotationTransition(
                          turns: logoAnimationController,
                          child: const ImmichLogo(heroTag: 'logo'),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 8.0, bottom: 16),
                        child: ImmichTitleText(),
                      ),
                    ],
                  ),
                  Form(key: loginFormKey, child: loginWidget),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget buildVersionCompatWarning() {
    // Если необходимо, можно реализовать предупреждение о несовместимости версий.
    return const SizedBox.shrink();
  }
}
