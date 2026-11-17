import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, PlatformException;
import 'package:provider/provider.dart';
import '../../core/service/vpn_service.dart';

class ProfileEditorPage extends StatefulWidget {
  final String? profileId;
  final String? initialName;
  final String? initialConfig;
  final String? initialUrl;
  final bool importClipboard;
  final bool importFile;

  const ProfileEditorPage({
    super.key,
    this.profileId,
    this.initialName,
    this.initialConfig,
    this.initialUrl,
    this.importClipboard = false,
    this.importFile = false,
  });

  @override
  State<ProfileEditorPage> createState() => _ProfileEditorPageState();
}

class _ProfileEditorPageState extends State<ProfileEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _configController;
  late final TextEditingController _urlController;
  bool _saving = false;
  String? _error;

  bool get isNew => widget.profileId == null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _configController = TextEditingController(
      text: widget.initialConfig ?? '{}',
    );
    _urlController = TextEditingController(text: widget.initialUrl ?? '');
    if (!isNew && widget.initialConfig == null) _loadConfig();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.importClipboard) _importFromClipboard();
      if (widget.importFile) _importFromFile();
    });
  }

  Future<void> _loadConfig() async {
    final config = await context.read<VpnService>().getProfileConfig(
      widget.profileId!,
    );
    if (!mounted || config == null) return;
    _configController.text = _formatJson(config);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _configController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  String _formatJson(String json) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(json));
    } catch (_) {
      return json;
    }
  }

  void _format() {
    try {
      final formatted = const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(_configController.text));
      _configController.text = formatted;
      setState(() => _error = null);
    } on FormatException catch (error) {
      setState(() => _error = 'JSON 格式错误: $error');
    }
  }

  Future<void> _validate() async {
    final config = _configController.text;
    try {
      jsonDecode(config);
    } on FormatException catch (error) {
      setState(() => _error = 'JSON 格式错误: $error');
      return;
    }
    final error = await context.read<VpnService>().checkConfig(config);
    if (!mounted) return;
    setState(() => _error = error == null ? null : '配置错误: $error');
    if (error == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('配置校验通过')));
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入配置名称');
      return;
    }
    final config = _configController.text;
    try {
      jsonDecode(config);
    } on FormatException catch (error) {
      setState(() => _error = 'JSON 格式错误: $error');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final vpn = context.read<VpnService>();
    final error = await vpn.checkConfig(config);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = '配置错误: $error';
      });
      return;
    }
    final url = _urlController.text.trim();
    try {
      await vpn.saveProfile(
        id: widget.profileId,
        name: name,
        config: config,
        url: url.isEmpty ? null : url,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：${error.message ?? error.code}';
      });
    }
  }

  Future<void> _fetchFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请输入订阅地址');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = await context.read<VpnService>().fetchSubscription(url);
    if (!mounted) return;
    if (body == null) {
      setState(() {
        _saving = false;
        _error = '获取订阅失败';
      });
      return;
    }
    try {
      jsonDecode(body);
      setState(() {
        _configController.text = _formatJson(body);
        _saving = false;
      });
    } on FormatException {
      setState(() {
        _saving = false;
        _error = '订阅内容不是有效 JSON';
      });
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      setState(() => _error = '剪贴板为空');
      return;
    }
    try {
      jsonDecode(text);
      setState(() {
        _configController.text = _formatJson(text);
        _error = null;
      });
    } on FormatException {
      setState(() => _error = '剪贴板内容不是有效 JSON');
    }
  }

  Future<void> _importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    try {
      final text = await File(path).readAsString();
      jsonDecode(text);
      if (!mounted) return;
      setState(() {
        _configController.text = _formatJson(text);
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() => _error = '文件内容不是有效 JSON: $error');
    } on FileSystemException catch (error) {
      setState(() => _error = '文件读取失败: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? '新建配置' : '编辑配置'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: '订阅链接（可选）',
                    hintText: 'https://…',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _fetchFromUrl,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('获取订阅'),
                  ),
                ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _format,
                      icon: const Icon(Icons.format_align_left, size: 18),
                      label: const Text('格式化'),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _validate,
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      label: const Text('校验'),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _importFromClipboard,
                      tooltip: '从剪贴板导入',
                      icon: const Icon(Icons.content_paste),
                    ),
                    IconButton(
                      onPressed: _importFromFile,
                      tooltip: '从文件导入',
                      icon: const Icon(Icons.folder_open),
                    ),
                  ],
                ),
                SizedBox(
                  height: 480,
                  child: TextField(
                    controller: _configController,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'sing-box JSON',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
