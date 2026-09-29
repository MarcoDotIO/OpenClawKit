import Foundation

/// Drops loader and interpreter injection variables from a stdio MCP server's configured `env`
/// (upstream `toMcpEnvRecord` / `isDangerousMcpStdioEnvVarName`, ported from
/// `src/infra/host-env-security-policy.json`).
///
/// The exec allowlist only restricts the executable path, so variables such as `LD_PRELOAD`,
/// `DYLD_INSERT_LIBRARIES` or `NODE_OPTIONS` would otherwise turn an allowlisted binary into arbitrary
/// code execution. Keys are compared trimmed and uppercased. Explicit credentials (`GITHUB_TOKEN`,
/// `AWS_ACCESS_KEY_ID`, `DATABASE_URL`, …) stay allowed.
public enum MCPStdioEnvironmentPolicy {
    /// Prefixes blocked everywhere (`DYLD_`, `LD_`, `BASH_FUNC_`).
    public static let blockedPrefixes: [String] = ["BASH_FUNC_", "DYLD_", "LD_"]

    /// Keys blocked everywhere (interpreter and loader hooks).
    static let blockedEverywhereKeys: Set<String> = [
        "ANT_OPTS", "BASHOPTS", "BASH_ENV", "BROWSER", "BZR_EDITOR", "BZR_PLUGIN_PATH", "BZR_SSH", "CARGO_BUILD_RUSTC",
        "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER", "CARGO_BUILD_RUSTC_WRAPPER", "CARGO_BUILD_RUSTDOC", "CATALINA_OPTS", "CC",
        "CMAKE_CXX_COMPILER", "CMAKE_C_COMPILER", "CMAKE_TOOLCHAIN_FILE", "CONFIG_SHELL", "CONFIG_SITE", "CORECLR_PROFILER",
        "CPP", "CXX", "CXXCPP", "DOTNET_ADDITIONAL_DEPS", "DOTNET_STARTUP_HOOKS", "ELIXIR_ERL_OPTIONS", "EMACSLOADPATH", "ENV",
        "ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS", "EXINIT", "FPATH", "GCONV_PATH", "GIT_ALLOW_PROTOCOL",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_DIR", "GIT_EDITOR", "GIT_EXEC_PATH", "GIT_EXTERNAL_DIFF",
        "GIT_HOOK_PATH", "GIT_INDEX_FILE", "GIT_NAMESPACE", "GIT_OBJECT_DIRECTORY", "GIT_PROTOCOL_FROM_USER",
        "GIT_SEQUENCE_EDITOR", "GIT_SSL_CAINFO", "GIT_SSL_CAPATH", "GIT_SSL_NO_VERIFY", "GIT_TEMPLATE_DIR", "GIT_WORK_TREE",
        "GLIBC_TUNABLES", "GRADLE_OPTS", "GVIMINIT", "HELM_PLUGINS", "HGEDITOR", "HGMERGE", "HGRCPATH", "HOSTALIASES", "IFS",
        "JAVA_OPTS", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "JULIA_EDITOR", "KSH_ENV", "LUA_INIT", "LUA_INIT_5_1",
        "LUA_INIT_5_2", "LUA_INIT_5_3", "LUA_INIT_5_4", "MAKE", "MAKEFLAGS", "MAVEN_OPTS", "MFLAGS", "MYVIMRC", "NODE_OPTIONS",
        "NODE_PATH", "NODE_REDIRECT_WARNINGS", "NODE_REPL_EXTERNAL_MODULE", "NODE_REPL_HISTORY", "NODE_V8_COVERAGE",
        "PACKER_PLUGIN_PATH", "PERL5LIB", "PERL5OPT", "PS4", "PYTHONBREAKPOINT", "PYTHONHOME", "PYTHONPATH", "RUBYLIB",
        "RUBYOPT", "RUBYSHELL", "RUSTC", "RUSTC_WORKSPACE_WRAPPER", "RUSTC_WRAPPER", "RUSTDOC", "R_ENVIRON", "R_ENVIRON_USER",
        "R_PROFILE", "R_PROFILE_USER", "SBT_OPTS", "SHELL", "SHELLOPTS", "SSLKEYLOGFILE", "SUDO_ASKPASS", "SVN_EDITOR",
        "SVN_SSH", "TCLLIBPATH", "VAGRANT_VAGRANTFILE", "VIMINIT", "_JAVA_OPTIONS"
    ]

    /// Override-only keys that are also blocked for MCP servers (config and credential-file pivots).
    static let blockedInheritedKeys: Set<String> = [
        "AMQP_URL", "ANSIBLE_CALLBACK_PLUGINS", "ANSIBLE_COLLECTIONS_PATH", "ANSIBLE_CONFIG", "ANSIBLE_CONNECTION_PLUGINS",
        "ANSIBLE_FILTER_PLUGINS", "ANSIBLE_INVENTORY_PLUGINS", "ANSIBLE_LIBRARY", "ANSIBLE_LOOKUP_PLUGINS",
        "ANSIBLE_MODULE_UTILS", "ANSIBLE_REMOTE_TEMP", "ANSIBLE_ROLES_PATH", "ANSIBLE_STRATEGY_PLUGINS", "AWS_ACCESS_KEY_ID",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_SECRET_ACCESS_KEY",
        "AWS_SECURITY_TOKEN", "AWS_SESSION_TOKEN", "AZURE_CLIENT_ID", "AZURE_CLIENT_SECRET", "BUNDLE_GEMFILE",
        "BUN_CONFIG_REGISTRY", "CARGO_HOME", "CFLAGS", "CGO_CFLAGS", "CGO_LDFLAGS", "CLASSPATH", "COMPOSER_HOME",
        "CONDA_DEFAULT_ENV", "CONDA_PREFIX", "CORECLR_PROFILER_PATH", "CPATH", "CPLUS_INCLUDE_PATH", "CURL_HOME",
        "C_INCLUDE_PATH", "DATABASE_URL", "DENO_DIR", "EDITOR", "FCEDIT", "GEM_HOME", "GEM_PATH", "GH_TOKEN", "GITHUB_TOKEN",
        "GITLAB_TOKEN", "GIT_ASKPASS", "GIT_PROXY_COMMAND", "GIT_SSH", "GIT_SSH_COMMAND", "GOENV", "GOFLAGS", "GONOPROXY",
        "GONOSUMCHECK", "GONOSUMDB", "GOPATH", "GOPRIVATE", "GOPROXY", "HELM_HOME", "LDFLAGS", "LESSCLOSE", "LESSOPEN",
        "LIBRARY_PATH", "LUA_CPATH", "LUA_PATH", "MONGODB_URI", "NODE_AUTH_TOKEN", "NPM_TOKEN", "OBJC_INCLUDE_PATH",
        "OPENSSL_CONF", "OPENSSL_ENGINES", "PERL5DB", "PERL5DBCMD", "PHPRC", "PHP_INI_SCAN_DIR", "PIP_CONFIG_FILE",
        "PIP_EXTRA_INDEX_URL", "PIP_FIND_LINKS", "PIP_INDEX_URL", "PIP_PYPI_URL", "PIP_TRUSTED_HOST", "PROMPT_COMMAND",
        "PYTHONSTARTUP", "PYTHONUSERBASE", "REDIS_URL", "RUSTFLAGS", "R_LIBS_USER", "SSH_ASKPASS", "SUDO_EDITOR",
        "TF_CLI_CONFIG_FILE", "TF_PLUGIN_CACHE_DIR", "UV_DEFAULT_INDEX", "UV_EXTRA_INDEX_URL", "UV_INDEX", "UV_INDEX_URL",
        "UV_PYTHON", "VIRTUAL_ENV", "VISUAL", "WGETRC", "YARN_RC_FILENAME"
    ]

    /// Explicit credentials exempt from the inherited-key block (upstream `MCP_EXPLICIT_CREDENTIAL_ENV_KEYS`).
    static let explicitCredentialKeys: Set<String> = [
        "AMQP_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SECURITY_TOKEN", "AWS_SESSION_TOKEN", "AZURE_CLIENT_ID",
        "AZURE_CLIENT_SECRET", "DATABASE_URL", "GH_TOKEN", "GITHUB_TOKEN", "GITLAB_TOKEN", "MONGODB_URI", "NODE_AUTH_TOKEN",
        "NPM_TOKEN", "REDIS_URL"
    ]

    /// Whether a configured `env` key is dropped before launching a stdio server.
    /// - Parameter rawKey: Environment variable name as configured.
    /// - Returns: `true` for loader, interpreter and config-pivot variables.
    public static func isDangerous(_ rawKey: String) -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return false }
        if self.blockedEverywhereKeys.contains(key) || self.blockedPrefixes.contains(where: { key.hasPrefix($0) }) {
            return true
        }
        if self.explicitCredentialKeys.contains(key) { return false }
        return self.blockedInheritedKeys.contains(key)
    }

    /// Splits a configured environment into the entries that are passed on and the dropped keys.
    /// - Parameter env: Configured environment.
    /// - Returns: The allowed entries and the dropped keys (sorted).
    public static func sanitize(_ env: [String: String]) -> (allowed: [String: String], dropped: [String]) {
        var allowed: [String: String] = [:]
        var dropped: [String] = []
        for (key, value) in env {
            if self.isDangerous(key) {
                dropped.append(key)
            } else {
                allowed[key] = value
            }
        }
        return (allowed, dropped.sorted())
    }
}
