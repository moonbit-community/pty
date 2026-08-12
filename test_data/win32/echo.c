#include <stdio.h>

int main(int argc, const char *argv[]) {
  for (int i = 1; i < argc; i++) {
    puts(argv[i]);
    putchar(' ');
  }
  return 0;
}
