import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'core/theme.dart';
import 'models/models.dart';
import 'services/auth_service.dart';
import 'services/api_service.dart';
import 'services/contacts_service.dart';
import 'services/signaling_service.dart';
import 'services/webrtc_service.dart';
import 'screens/splash_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/register_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/contacts/contacts_screen.dart';
import 'screens/call/incoming_call_screen.dart';
import 'screens/call/active_call_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoiceCallApp());
}

class VoiceCallApp extends StatefulWidget {
  const VoiceCallApp({super.key});

  @override
  State<VoiceCallApp> createState() => _VoiceCallAppState();
}

class _VoiceCallAppState extends State<VoiceCallApp> {
  late final AuthService _authService;
  late final ContactsService _contactsService;
  late final SignalingService _signalingService;
  late final WebRTCService _webRTCService;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _authService = AuthService();
    _contactsService = ContactsService(ApiService());
    _signalingService = SignalingService();
    _webRTCService = WebRTCService(_signalingService);

    _router = GoRouter(
      initialLocation: '/splash',
      refreshListenable: Listenable.merge([_authService, _webRTCService]),
      redirect: (context, state) {
        final isAuthenticated = _authService.isAuthenticated;
        final isOnAuth = state.matchedLocation.startsWith('/auth') ||
            state.matchedLocation == '/splash';

        if (!isAuthenticated && !isOnAuth) return '/auth/login';
        if (isAuthenticated && isOnAuth && state.matchedLocation != '/splash') {
          return '/home';
        }

        // Navigate to incoming call screen when ringing
        if (_webRTCService.callState == CallState.ringing &&
            !state.matchedLocation.startsWith('/call')) {
          return '/call/incoming';
        }
        if (_webRTCService.callState == CallState.connected &&
            !state.matchedLocation.startsWith('/call/active')) {
          return '/call/active';
        }
        return null;
      },
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
        GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/auth/register', builder: (_, __) => const RegisterScreen()),
        GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/contacts', builder: (_, __) => const ContactsScreen()),
        GoRoute(path: '/call/incoming', builder: (_, __) => const IncomingCallScreen()),
        GoRoute(path: '/call/active', builder: (_, __) => const ActiveCallScreen()),
        // Deep link: voicecall://join/:roomId  or  https://yourapp.com/join/:roomId
        GoRoute(
          path: '/join/:roomId',
          builder: (_, state) {
            final roomId = state.pathParameters['roomId']!;
            return HomeScreen(pendingRoomId: roomId);
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _signalingService.disconnect();
    _webRTCService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _authService),
        ChangeNotifierProvider.value(value: _contactsService),
        ChangeNotifierProvider.value(value: _signalingService),
        ChangeNotifierProvider.value(value: _webRTCService),
      ],
      child: MaterialApp.router(
        title: 'VoiceCall',
        theme: AppTheme.darkTheme,
        routerConfig: _router,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
