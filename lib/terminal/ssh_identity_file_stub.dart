Future<String> readSshIdentityFile(String configuredPath) =>
    Future.error(UnsupportedError('当前平台不能从本机路径读取 SSH 私钥'));
