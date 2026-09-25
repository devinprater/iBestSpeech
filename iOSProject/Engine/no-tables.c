/* Stand-in for the generated table index in a build that ships no tables.
 *
 * The library looks a build's compiled-in tables up through bst_lifted_for.
 * Returning NULL for everything is what makes bst_open() unavailable while
 * leaving bst_open_image() -- which reads the caller's own file -- untouched.
 * That is the whole mechanism of a table-free build: no engine change, just
 * different objects on the link line.
 */
#include <stddef.h>
#include "bst_text.h"

const bst_lifted *bst_lifted_for(const char *build) {
    (void)build;
    return NULL;
}
