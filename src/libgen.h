#ifndef CIRCUIT_SIM_LIBGEN_COMPAT_H
#define CIRCUIT_SIM_LIBGEN_COMPAT_H

#include <string.h>

static inline char *dirname(char *path) {
    char *last_slash;
    char *last_backslash;
    char *last_sep;

    if (path == 0 || path[0] == '\0') {
        return (char *)".";
    }

    last_slash = strrchr(path, '/');
    last_backslash = strrchr(path, '\\');
    last_sep = last_slash > last_backslash ? last_slash : last_backslash;

    if (last_sep == 0) {
        return (char *)".";
    }

    while (last_sep > path && (last_sep[-1] == '/' || last_sep[-1] == '\\')) {
        last_sep--;
    }

    if (last_sep == path) {
        last_sep[1] = '\0';
        return path;
    }

    *last_sep = '\0';
    return path;
}

#endif
