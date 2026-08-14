#include <stdio.h>

int main(int argc, const char *argv[]) {
  for (int i = 1; i < argc; i++) {
    puts(argv[i]);
    if (i < argc - 1) {
      putchar(' ');
    }
  }
  return 0;
}
