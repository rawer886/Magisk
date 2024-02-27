#include <libgen.h>
#include <sys/types.h>
#include <sys/stat.h>

#include <consts.hpp>
#include <selinux.hpp>
#include <base.hpp>

using namespace std;

struct Applet {
    string_view name;
    int (*fn)(int, char *[]);
};

constexpr Applet applets[] = {
    { "su", su_client_main },
    { "resetprop", resetprop_main },
};

constexpr Applet private_applets[] = {
    { "zygisk", zygisk_main },
};

/**
 * 创建 su 和 resetprop 两个 applet
 * 通过 magisk.cpp 来查看
 */
int main(int argc, char *argv[]) {
    //LOGD("jiayg applets main 被调用\n");
    if (argc < 1)
        return 1;

    cmdline_logging();
    init_argv0(argc, argv);

    //获取文件的名字
    string_view argv0 = basename(argv[0]);

    umask(0);

    if (argv[0][0] == '\0') {
        // When argv[0] is an empty string, we're calling private applets
        if (argc < 2)
            return 1;
        --argc;
        ++argv;
        for (const auto &app : private_applets) {
            if (argv[0] == app.name) {
                return app.fn(argc, argv);
            }
        }
        fprintf(stderr, "%s: applet not found\n", argv[0]);
        return 1;
    }

    if (argv0 == "magisk" || argv0 == "magisk32" || argv0 == "magisk64") {
        if (argc > 1 && argv[1][0] != '-') {
            // Calling applet with "magisk [applet] args..."
            --argc;
            ++argv;
            argv0 = argv[0];
        } else {
            return magisk_main(argc, argv);
        }
    }

    for (const auto &app : applets) {
        if (argv0 == app.name) {
            return app.fn(argc, argv);
        }
    }
    fprintf(stderr, "%s: applet not found\n", argv0.data());
    return 1;
}
