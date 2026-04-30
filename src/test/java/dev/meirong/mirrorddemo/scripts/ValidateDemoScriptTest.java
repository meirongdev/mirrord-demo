package dev.meirong.mirrorddemo.scripts;

import static org.junit.jupiter.api.Assertions.assertNotEquals;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermission;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ValidateDemoScriptTest {

    @Test
    void validateScriptFailsWhenHeaderStealNeverReachesLocal(@TempDir Path tempDir) throws Exception {
        ProcessResult result = runValidateDemo(tempDir, "always-cluster");

        assertNotEquals(0, result.exitCode(), () -> """
            Expected scripts/validate-demo.sh to fail when header-based stealing never reaches the local process.
            Actual output:
            """ + result.output());
    }

    @Test
    void validateScriptWaitsForHeaderStealToBecomeReady(@TempDir Path tempDir) throws Exception {
        ProcessResult result = runValidateDemo(tempDir, "delayed-local");

        assertNotEquals(-1, result.output().indexOf("Incoming steal also worked on this cluster"), () -> """
            Expected scripts/validate-demo.sh to keep polling until header-based stealing reached the local process.
            Actual output:
            """ + result.output());
    }

    private static ProcessResult runValidateDemo(Path tempDir, String stealBehavior) throws Exception {
        Path repoRoot = Path.of(System.getProperty("user.dir"));
        Path binDir = Files.createDirectories(tempDir.resolve("bin"));
        Files.writeString(tempDir.resolve("message.txt"), "hello from cluster", StandardCharsets.UTF_8);
        Files.writeString(tempDir.resolve("steal-attempts.txt"), "0", StandardCharsets.UTF_8);

        writeExecutable(binDir.resolve("curl"), """
            #!/usr/bin/env bash
            set -euo pipefail

            state_dir="${STUB_STATE_DIR:?}"
            message_file="$state_dir/message.txt"
            attempts_file="$state_dir/steal-attempts.txt"
            steal_behavior="${STEAL_BEHAVIOR:?}"
            method="GET"
            steal_header="false"
            url=""

            while (($#)); do
              case "$1" in
                -X)
                  method="$2"
                  shift 2
                  ;;
                -d)
                  if [[ "$2" == *"hello from cluster"* ]]; then
                    printf '%s' 'hello from cluster' >"$message_file"
                  elif [[ "$2" == *"updated through local"* ]]; then
                    printf '%s' 'updated through local' >"$message_file"
                  fi
                  shift 2
                  ;;
                -H)
                  if [[ "$2" == "x-mirrord-mode: steal" ]]; then
                    steal_header="true"
                  fi
                  shift 2
                  ;;
                -f|-s|-S|-fsS)
                  shift
                  ;;
                http://*)
                  url="$1"
                  shift
                  ;;
                *)
                  shift
                  ;;
              esac
            done

            message="$(cat "$message_file")"

            if [[ "$url" == "http://127.0.0.1:8080/api/messages/current" ]]; then
              printf '{"message":"%s","handledBy":"local"}\n' "$message"
              exit 0
            fi

            if [[ "$url" == "http://127.0.0.1:18080/api/messages/current" ]]; then
              if [[ "$steal_header" == "true" && "$steal_behavior" == "delayed-local" ]]; then
                attempts="$(cat "$attempts_file")"
                attempts="$((attempts + 1))"
                printf '%s' "$attempts" >"$attempts_file"
                if (( attempts >= 3 )); then
                  printf '{"message":"%s","handledBy":"local"}\n' "$message"
                  exit 0
                fi
              fi
              printf '{"message":"%s","handledBy":"cluster"}\n' "$message"
              exit 0
            fi

            printf 'unexpected url: %s\n' "$url" >&2
            exit 1
            """);

        writeExecutable(binDir.resolve("docker"), """
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "${1:-}" == "inspect" ]]; then
              printf '{"30080/tcp":[{"HostPort":"18080"}]}\n'
            fi
            """);

        writeExecutable(binDir.resolve("kind"), """
            #!/usr/bin/env bash
            set -euo pipefail
            if [[ "${1:-}" == "get" && "${2:-}" == "clusters" ]]; then
              printf 'mirrord-demo\n'
            fi
            """);

        writeExecutable(binDir.resolve("kubectl"), """
            #!/usr/bin/env bash
            set -euo pipefail
            """);

        writeExecutable(binDir.resolve("mvn"), """
            #!/usr/bin/env bash
            set -euo pipefail
            """);

        writeExecutable(binDir.resolve("java"), """
            #!/usr/bin/env bash
            set -euo pipefail
            """);

        writeExecutable(binDir.resolve("mirrord"), """
            #!/usr/bin/env bash
            set -euo pipefail
            sleep 30
            """);

        writeExecutable(binDir.resolve("sleep"), """
            #!/usr/bin/env bash
            set -euo pipefail
            """);

        ProcessBuilder processBuilder = new ProcessBuilder("bash", "scripts/validate-demo.sh");
        processBuilder.directory(repoRoot.toFile());
        processBuilder.redirectErrorStream(true);
        processBuilder.environment().put("PATH", binDir + ":" + processBuilder.environment().get("PATH"));
        processBuilder.environment().put("STUB_STATE_DIR", tempDir.toString());
        processBuilder.environment().put("STEAL_BEHAVIOR", stealBehavior);

        Process process = processBuilder.start();
        String output;
        try (var inputStream = process.getInputStream()) {
            output = new String(inputStream.readAllBytes(), StandardCharsets.UTF_8);
        }
        int exitCode = process.waitFor();

        return new ProcessResult(exitCode, output);
    }

    private static void writeExecutable(Path path, String script) throws IOException {
        Files.writeString(path, script, StandardCharsets.UTF_8);
        Files.setPosixFilePermissions(path, Set.of(
            PosixFilePermission.OWNER_READ,
            PosixFilePermission.OWNER_WRITE,
            PosixFilePermission.OWNER_EXECUTE));
    }

    private record ProcessResult(int exitCode, String output) {
    }
}
