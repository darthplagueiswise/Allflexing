// Copyright (c) 2013, Facebook, Inc.
// All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//   * Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//   * Neither the name Facebook nor the names of its contributors may be used to
//     endorse or promote products derived from this software without specific
//     prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "flex_fishhook.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct rebindings_entry {
    struct rebinding *rebindings;
    size_t rebindings_nel;
    struct rebindings_entry *next;
};

static struct rebindings_entry *g_flex_rebindings_head;

static int flex_prepend_rebindings(struct rebindings_entry **head,
                                   struct rebinding rebindings[],
                                   size_t count) {
    struct rebindings_entry *entry = malloc(sizeof(struct rebindings_entry));
    if (!entry) {
        return -1;
    }
    entry->rebindings = malloc(sizeof(struct rebinding) * count);
    if (!entry->rebindings) {
        free(entry);
        return -1;
    }
    memcpy(entry->rebindings, rebindings, sizeof(struct rebinding) * count);
    entry->rebindings_nel = count;
    entry->next = *head;
    *head = entry;
    return 0;
}

static size_t flex_perform_rebinding_with_section(
    struct rebindings_entry *rebindings,
    section_t *section,
    intptr_t slide,
    nlist_t *symtab,
    char *strtab,
    uint32_t *indirect_symtab
) {
    uint32_t *symbol_indices = indirect_symtab + section->reserved1;
    void **bindings = (void **)((uintptr_t)slide + section->addr);
    size_t rebound_count = 0;

    for (uint index = 0; index < section->size / sizeof(void *); index++) {
        uint32_t symbol_index = symbol_indices[index];
        if (symbol_index == INDIRECT_SYMBOL_ABS ||
            symbol_index == INDIRECT_SYMBOL_LOCAL ||
            symbol_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }

        uint32_t string_offset = symtab[symbol_index].n_un.n_strx;
        char *symbol_name = strtab + string_offset;
        bool has_name = symbol_name[0] && symbol_name[1];
        struct rebindings_entry *current = rebindings;
        while (current) {
            for (uint binding_index = 0;
                 binding_index < current->rebindings_nel;
                 binding_index++) {
                struct rebinding *rebinding = &current->rebindings[binding_index];
                if (!has_name || strcmp(&symbol_name[1], rebinding->name) != 0) {
                    continue;
                }

                // iOS 15+ enforces __DATA_CONST. Match first, then request the
                // narrow copy-on-write permission used by current fishhook.
                // Never report/install a replacement if the kernel rejects it.
                kern_return_t protection_status = vm_protect(
                    mach_task_self(),
                    (vm_address_t)bindings,
                    (vm_size_t)section->size,
                    false,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
                );
                if (protection_status == KERN_SUCCESS) {
                    if (rebinding->replaced && bindings[index] != rebinding->replacement) {
                        *rebinding->replaced = bindings[index];
                    }
                    bindings[index] = rebinding->replacement;
                    rebound_count += 1;
                }
                goto symbol_loop;
            }
            current = current->next;
        }

    symbol_loop:;
    }
    return rebound_count;
}

static size_t flex_rebind_symbols_for_image(
    struct rebindings_entry *rebindings,
    const struct mach_header *header,
    intptr_t slide
) {
    Dl_info info;
    if (dladdr(header, &info) == 0) {
        return 0;
    }

    segment_command_t *segment = NULL;
    segment_command_t *linkedit = NULL;
    struct symtab_command *symtab_command = NULL;
    struct dysymtab_command *dysymtab_command = NULL;
    uintptr_t cursor = (uintptr_t)header + sizeof(mach_header_t);

    for (uint command_index = 0;
         command_index < header->ncmds;
         command_index++, cursor += segment->cmdsize) {
        segment = (segment_command_t *)cursor;
        if (segment->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            }
        } else if (segment->cmd == LC_SYMTAB) {
            symtab_command = (struct symtab_command *)segment;
        } else if (segment->cmd == LC_DYSYMTAB) {
            dysymtab_command = (struct dysymtab_command *)segment;
        }
    }

    if (!symtab_command || !dysymtab_command || !linkedit ||
        !dysymtab_command->nindirectsyms) {
        return 0;
    }

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_command->symoff);
    char *strtab = (char *)(linkedit_base + symtab_command->stroff);
    uint32_t *indirect_symtab =
        (uint32_t *)(linkedit_base + dysymtab_command->indirectsymoff);

    size_t rebound_count = 0;
    cursor = (uintptr_t)header + sizeof(mach_header_t);
    for (uint command_index = 0;
         command_index < header->ncmds;
         command_index++, cursor += segment->cmdsize) {
        segment = (segment_command_t *)cursor;
        if (segment->cmd != LC_SEGMENT_ARCH_DEPENDENT ||
            (strcmp(segment->segname, SEG_DATA) != 0 &&
             strcmp(segment->segname, SEG_DATA_CONST) != 0)) {
            continue;
        }

        for (uint section_index = 0;
             section_index < segment->nsects;
             section_index++) {
            section_t *section =
                (section_t *)(cursor + sizeof(segment_command_t)) + section_index;
            uint32_t type = section->flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS ||
                type == S_NON_LAZY_SYMBOL_POINTERS) {
                rebound_count += flex_perform_rebinding_with_section(
                    rebindings,
                    section,
                    slide,
                    symtab,
                    strtab,
                    indirect_symtab
                );
            }
        }
    }
    return rebound_count;
}

static void flex_rebind_new_image(const struct mach_header *header,
                                  intptr_t slide) {
    (void)flex_rebind_symbols_for_image(g_flex_rebindings_head, header, slide);
}

int flex_rebind_symbols_image(void *header,
                              intptr_t slide,
                              struct rebinding rebindings[],
                              size_t rebindings_nel) {
    struct rebindings_entry *head = NULL;
    int result = flex_prepend_rebindings(&head, rebindings, rebindings_nel);
    if (result < 0) {
        return result;
    }

    size_t rebound_count = flex_rebind_symbols_for_image(
        head,
        (const struct mach_header *)header,
        slide
    );
    free(head->rebindings);
    free(head);
    return rebound_count > 0 ? 0 : -2;
}

int flex_rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
    int result = flex_prepend_rebindings(
        &g_flex_rebindings_head,
        rebindings,
        rebindings_nel
    );
    if (result < 0) {
        return result;
    }

    if (!g_flex_rebindings_head->next) {
        _dyld_register_func_for_add_image(flex_rebind_new_image);
    } else {
        uint32_t image_count = _dyld_image_count();
        for (uint32_t index = 0; index < image_count; index++) {
            flex_rebind_new_image(
                _dyld_get_image_header(index),
                _dyld_get_image_vmaddr_slide(index)
            );
        }
    }
    return 0;
}
