import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/telegram_service.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Phone number step
  final TextEditingController _phoneController = TextEditingController();
  String _selectedCountryCode = '+91';
  bool _isSendingPhone = false;

  // OTP step
  final List<TextEditingController> _otpControllers =
      List.generate(5, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes =
      List.generate(5, (_) => FocusNode());
  bool _isVerifyingCode = false;

  // Password step (2FA)
  final TextEditingController _passwordController = TextEditingController();
  bool _isVerifyingPassword = false;
  bool _obscurePassword = true;

  late AnimationController _animController;
  late Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _slideAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    );
    _animController.forward();

    // Listen for auth state changes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TelegramService>().addListener(_onAuthStateChanged);
    });
  }

  void _onAuthStateChanged() {
    if (!mounted) return;
    final service = context.read<TelegramService>();

    switch (service.authState) {
      case AuthState.waitingCode:
        if (_currentPage != 1) _goToPage(1);
        break;
      case AuthState.waitingPassword:
        if (_currentPage != 2) _goToPage(2);
        break;
      case AuthState.authorized:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
        break;
      case AuthState.error:
        _showError(service.errorMessage);
        break;
      default:
        break;
    }
  }

  void _goToPage(int page) {
    setState(() => _currentPage = page);
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFCF6679),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _submitPhone() async {
    final phone = '$_selectedCountryCode${_phoneController.text.trim()}';
    if (_phoneController.text.trim().isEmpty) {
      _showError('Please enter your phone number');
      return;
    }
    setState(() => _isSendingPhone = true);
    final service = context.read<TelegramService>();
    final success = await service.sendPhoneNumber(phone);
    if (mounted) setState(() => _isSendingPhone = false);
    if (!success && mounted) {
      _showError(service.errorMessage.isNotEmpty
          ? service.errorMessage
          : 'Failed to send code');
    }
  }

  Future<void> _submitOtp() async {
    final code = _otpControllers.map((c) => c.text).join();
    if (code.length < 5) {
      _showError('Please enter the complete 5-digit code');
      return;
    }
    setState(() => _isVerifyingCode = true);
    final service = context.read<TelegramService>();
    final success = await service.sendOtpCode(code);
    if (mounted) setState(() => _isVerifyingCode = false);
    if (!success && mounted) {
      _showError(service.errorMessage.isNotEmpty
          ? service.errorMessage
          : 'Invalid code');
    }
  }

  Future<void> _submitPassword() async {
    if (_passwordController.text.isEmpty) {
      _showError('Please enter your 2FA password');
      return;
    }
    setState(() => _isVerifyingPassword = true);
    final service = context.read<TelegramService>();
    final success = await service.sendPassword(_passwordController.text);
    if (mounted) setState(() => _isVerifyingPassword = false);
    if (!success && mounted) {
      _showError(service.errorMessage.isNotEmpty
          ? service.errorMessage
          : 'Invalid password');
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    for (final c in _otpControllers) {
      c.dispose();
    }
    for (final f in _otpFocusNodes) {
      f.dispose();
    }
    _animController.dispose();
    try {
      context.read<TelegramService>().removeListener(_onAuthStateChanged);
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildPhonePage(),
            _buildOtpPage(),
            _buildPasswordPage(),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────
  // Page 1: Phone Number
  // ──────────────────────────────────────────
  Widget _buildPhonePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          _buildLogo(),
          const SizedBox(height: 48),
          const Text(
            'Your Phone',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter your Telegram phone number to sign in',
            style: TextStyle(color: Color(0xFF9090B0), fontSize: 15),
          ),
          const SizedBox(height: 36),

          // Country code + phone
          Row(
            children: [
              _buildCountryCodePicker(),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    hintText: '98765 43210',
                    prefixIcon: Icon(Icons.phone_outlined, color: Color(0xFF2AABEE)),
                  ),
                  onSubmitted: (_) => _submitPhone(),
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSendingPhone ? null : _submitPhone,
              child: _isSendingPhone
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Send Code'),
            ),
          ),

          const SizedBox(height: 24),
          _buildInfoBox(
            icon: Icons.lock_outline,
            text:
                'We use the official Telegram API. Your credentials are never shared.',
          ),
        ],
      ),
    );
  }

  Widget _buildCountryCodePicker() {
    final codes = [
      '+91', '+1', '+44', '+61', '+971', '+65',
      '+49', '+33', '+7', '+86', '+81', '+82',
    ];
    return GestureDetector(
      onTap: () async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: const Color(0xFF141420),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (ctx) => ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: codes
                .map((c) => ListTile(
                      title: Text(c,
                          style: const TextStyle(color: Colors.white, fontSize: 16)),
                      onTap: () => Navigator.pop(ctx, c),
                    ))
                .toList(),
          ),
        );
        if (picked != null) setState(() => _selectedCountryCode = picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(
              _selectedCountryCode,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, color: Color(0xFF2AABEE), size: 20),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────
  // Page 2: OTP Code
  // ──────────────────────────────────────────
  Widget _buildOtpPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          _buildLogo(),
          const SizedBox(height: 48),
          const Text(
            'Enter Code',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We sent a 5-digit code to\n$_selectedCountryCode ${_phoneController.text.trim()}',
            style: const TextStyle(color: Color(0xFF9090B0), fontSize: 15),
          ),
          const SizedBox(height: 36),

          // OTP input boxes
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(
              5,
              (i) => _buildOtpBox(i),
            ),
          ),

          const SizedBox(height: 36),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isVerifyingCode ? null : _submitOtp,
              child: _isVerifyingCode
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Verify Code'),
            ),
          ),

          const SizedBox(height: 16),
          TextButton(
            onPressed: () => _goToPage(0),
            child: const Text(
              '← Change phone number',
              style: TextStyle(color: Color(0xFF2AABEE)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOtpBox(int index) {
    return SizedBox(
      width: 52,
      height: 60,
      child: TextField(
        controller: _otpControllers[index],
        focusNode: _otpFocusNodes[index],
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 1,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          counterText: '',
          contentPadding: EdgeInsets.zero,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2A2A40), width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2AABEE), width: 2),
          ),
          filled: true,
          fillColor: const Color(0xFF1A1A2E),
        ),
        onChanged: (value) {
          if (value.isNotEmpty && index < 4) {
            _otpFocusNodes[index + 1].requestFocus();
          } else if (value.isEmpty && index > 0) {
            _otpFocusNodes[index - 1].requestFocus();
          }
          // Auto-submit when all 5 digits entered
          if (index == 4 && value.isNotEmpty) {
            _submitOtp();
          }
        },
      ),
    );
  }

  // ──────────────────────────────────────────
  // Page 3: 2FA Password
  // ──────────────────────────────────────────
  Widget _buildPasswordPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          _buildLogo(),
          const SizedBox(height: 48),
          const Text(
            'Two-Step Verification',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your account has 2FA enabled. Enter your password to continue.',
            style: TextStyle(color: Color(0xFF9090B0), fontSize: 15),
          ),
          const SizedBox(height: 36),

          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Cloud password',
              prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF2AABEE)),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off : Icons.visibility,
                  color: const Color(0xFF606080),
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            onSubmitted: (_) => _submitPassword(),
          ),

          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isVerifyingPassword ? null : _submitPassword,
              child: _isVerifyingPassword
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Sign In'),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────
  // Shared Widgets
  // ──────────────────────────────────────────
  Widget _buildLogo() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF2AABEE), Color(0xFF1A7FBF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2AABEE).withOpacity(0.3),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Icon(Icons.play_circle_rounded, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 12),
        const Text(
          'TG Streamer',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoBox({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A40)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF2AABEE), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFF9090B0),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
