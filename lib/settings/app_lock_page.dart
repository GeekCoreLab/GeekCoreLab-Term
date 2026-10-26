import 'package:flutter/material.dart';

import 'app_settings.dart';

class AppLockPage extends StatefulWidget {
  const AppLockPage({required this.settings, super.key});

  final AppSettingsController settings;

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

class _AppLockPageState extends State<AppLockPage> {
  final _passwordController = TextEditingController();
  String? _error;
  bool _unlocking = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    setState(() {
      _unlocking = true;
      _error = null;
    });
    bool unlocked;
    try {
      unlocked = await widget.settings.unlock(_passwordController.text);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _unlocking = false;
        _error = '验证主密码失败：$error';
      });
      return;
    }
    if (!mounted) return;
    if (!unlocked) {
      setState(() {
        _unlocking = false;
        _error = '主密码不正确，请重试';
        _passwordController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 42,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Geekcore Term',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '输入主密码以解锁终端工作区',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _passwordController,
                      autofocus: true,
                      obscureText: true,
                      onSubmitted: (_) => _unlock(),
                      decoration: InputDecoration(
                        labelText: '主密码',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        errorText: _error,
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _unlocking ? null : _unlock,
                        icon: _unlocking
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_open_rounded),
                        label: Text(_unlocking ? '正在验证' : '解锁'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
