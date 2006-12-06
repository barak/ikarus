
#include "ikarus.h"
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>   
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <assert.h>
#include <errno.h>

#define forward_ptr ((ikp)-1)
#define minimum_heap_size (pagesize * 1024 * 4)
#define maximum_heap_size (pagesize * 1024 * 8)
#define minimum_stack_size (pagesize * 128)

#define accounting 0

static int pair_count = 0;
static int symbol_count = 0;
static int closure_count = 0;
static int vector_count = 0;
static int record_count = 0;
static int continuation_count = 0;
static int string_count = 0;
static int htable_count = 0;

typedef struct qupages_t{
  ikp p;    /* pointer to the scan start */
  ikp q;    /* pointer to the scan end */
  struct qupages_t* next;
} qupages_t;


typedef struct{
  ikp ap;
  ikp aq;
  ikp ep;
  ikp base;
} meta_t;


#define meta_ptrs 0
#define meta_code 1
#define meta_data 2
#define meta_weak 3
#define meta_pair 4
#define meta_count 5

static int extension_amount[meta_count] = {
  4 * pagesize,
  1 * pagesize,
  4 * pagesize,
  1 * pagesize,
  1 * pagesize
};

static unsigned int meta_mt[meta_count] = {
  pointers_mt,
  code_mt,
  data_mt,
  weak_pairs_mt,
  pointers_mt
};

#define generation_count 5  /* generations 0 (nursery), 1, 2, 3, 4 */


typedef struct{
  meta_t meta[generation_count][meta_count];
  qupages_t* queues [meta_count];
  ikpcb* pcb;
  unsigned int* segment_vector;
  int collect_gen;
  ikp tconc_ap;
  ikp tconc_ep;
  ikp tconc_base;
  ikpages* tconc_queue;
} gc_t;

static unsigned int 
next_gen_tag[generation_count] = {
  (4 << meta_dirty_shift) | 1 | new_gen_tag,
  (2 << meta_dirty_shift) | 2 | new_gen_tag,
  (1 << meta_dirty_shift) | 3 | new_gen_tag,
  (0 << meta_dirty_shift) | 4 | new_gen_tag,
  (0 << meta_dirty_shift) | 4 | new_gen_tag
};

static ikp
meta_alloc_extending(int size, int old_gen, gc_t* gc, int meta_id){
  int mapsize = align_to_next_page(size);
  if(mapsize < extension_amount[meta_id]){
    mapsize = extension_amount[meta_id];
  }
  meta_t* meta = &gc->meta[old_gen][meta_id];
  if((meta_id != meta_data) &&  meta->base){
    qupages_t* p = ik_malloc(sizeof(qupages_t));
    ikp aq = meta->aq;
    ikp ap = meta->ap;
    ikp ep = meta->ep; 
    p->p = aq;
    p->q = ap;
    p->next = gc->queues[meta_id];
    gc->queues[meta_id] = p;
    ikp x = ap;
    while(x < ep){
      ref(x, 0) = 0;
      x += wordsize;
    }
  }

  ikp mem = ik_mmap_typed(
      mapsize, 
      meta_mt[meta_id] | next_gen_tag[old_gen],
      gc->pcb);
  gc->segment_vector = gc->pcb->segment_vector;
  meta->ap = mem + size;
  meta->aq = mem;
  meta->ep = mem + mapsize;
  meta->base = mem;
  return mem;
}




static inline ikp
meta_alloc(int size, int old_gen, gc_t* gc, int meta_id){
  assert(size == align(size));
  meta_t* meta = &gc->meta[old_gen][meta_id];
  ikp ap = meta->ap;
  ikp ep = meta->ep;
  ikp nap = ap + size;
  if(nap > ep){
    return meta_alloc_extending(size, old_gen, gc, meta_id);
  } else {
    meta->ap = nap;
    return ap;
  }
}

static inline ikp 
gc_alloc_new_ptr(int size, int old_gen, gc_t* gc){
  assert(size == align(size));
  return meta_alloc(size, old_gen, gc, meta_ptrs);
}

static inline ikp 
gc_alloc_new_pair(int old_gen, gc_t* gc){
  return meta_alloc(pair_size, old_gen, gc, meta_pair);
}



static inline ikp 
gc_alloc_new_weak_pair(int old_gen, gc_t* gc){
  meta_t* meta = &gc->meta[old_gen][meta_weak];
  ikp ap = meta->ap;
  ikp ep = meta->ep;
  ikp nap = ap + pair_size;
  if(nap > ep){
      ikp mem = ik_mmap_typed(
                   pagesize, 
                   meta_mt[meta_weak] | next_gen_tag[old_gen],
                   gc->pcb);
      gc->segment_vector = gc->pcb->segment_vector;
      meta->ap = mem + pair_size;
      meta->aq = mem;
      meta->ep = mem + pagesize;
      meta->base = mem;
      return mem;
  } else {
    meta->ap = nap;
    return ap;
  }
}

static inline ikp 
gc_alloc_new_data(int size, int old_gen, gc_t* gc){
  assert(size == align(size));
  return meta_alloc(size, old_gen, gc, meta_data);
}

static inline ikp 
gc_alloc_new_code(int size, int old_gen, gc_t* gc){
  if(size < pagesize){
    return meta_alloc(size, old_gen, gc, meta_code);
  } else {
    int memreq = align_to_next_page(size);
    ikp mem = ik_mmap_code(memreq, next_gen_tag[old_gen], gc->pcb);
    gc->segment_vector = gc->pcb->segment_vector;
    qupages_t* p = ik_malloc(sizeof(qupages_t));
    p->p = mem;
    p->q = mem+size;
    p->next = gc->queues[meta_code];
    gc->queues[meta_code] = p;
    return mem;
  }
}

static void
gc_tconc_push_extending(gc_t* gc, ikp tcbucket){
  if(gc->tconc_base){
    ikpages* p = ik_malloc(sizeof(ikpages));
    p->base = gc->tconc_base;
    p->size = pagesize;
    p->next = gc->tconc_queue;
    gc->tconc_queue = p;
  }
  ikp ap = ik_mmap(pagesize);
  ikp nap = ap + wordsize;
  gc->tconc_base = ap;
  gc->tconc_ap = nap;
  gc->tconc_ep = ap + pagesize;
  ref(ap,0) = tcbucket;
}


static inline void
gc_tconc_push(gc_t* gc, ikp tcbucket){
  ikp ap = gc->tconc_ap;
  ikp nap = ap + wordsize;
  if(nap > gc->tconc_ep){
    gc_tconc_push_extending(gc, tcbucket);
  } else {
    gc->tconc_ap = nap;
    ref(ap,0) = tcbucket;
  }
}

static ikp add_object(gc_t* gc, ikp x, char* caller);
static void collect_stack(gc_t*, ikp top, ikp base);
static void collect_loop(gc_t*);
static void fix_weak_pointers(gc_t*);
static void gc_add_tconcs(gc_t*);

/* ik_collect is called from scheme under the following conditions:
 * 1. An attempt is made to allocate a small object and the ap is above
 *    the red line.
 * 2. The current frame of the call is dead, so, upon return from ik_collect,
 *    the caller returns to its caller.
 * 3. The frame-pointer of the caller to S_collect is saved at
 *    pcb->frame_pointer.  No variables are live at that frame except for
 *    the return point (at *(pcb->frame_pointer)).
 * 4. S_collect must return a new ap (in pcb->allocation_pointer) that has
 *    at least 2 pages of memory free.
 * 5. S_collect must also update pcb->allocaton_redline to be 2 pages below
 *    the real end of heap.
 * 6. ik_collect should not move the stack.
 */


ikpcb* ik_collect(int req, ikpcb* pcb);
ikpcb* ik_collect_vararg(int req, ikpcb* pcb){
  return ik_collect(req, pcb);
}

static int collection_id_to_gen(int id){
  if((id & 255) == 255) { return 4; }
  if((id & 63) == 63) { return 3; }
  if((id & 15) == 15) { return 2; }
  if((id & 3) == 3) { return 1; }
  return 0;
}



static void scan_dirty_pages(gc_t*);

static void deallocate_unused_pages(gc_t*);

static void fix_new_pages(gc_t* gc);


ikpcb* 
ik_collect(int mem_req, ikpcb* pcb){

  struct rusage t0, t1;
   
  getrusage(RUSAGE_SELF, &t0);

  gc_t gc;
  bzero(&gc, sizeof(gc_t));
  gc.pcb = pcb;
  gc.segment_vector = pcb->segment_vector;

  gc.collect_gen = collection_id_to_gen(pcb->collection_id);
  pcb->collection_id++;
#ifndef NDEBUG
  fprintf(stderr, "ik_collect entry %d free=%d (collect gen=%d/id=%d)\n",
      mem_req,
      (unsigned int) pcb->allocation_redline
        - (unsigned int) pcb->allocation_pointer,
      gc.collect_gen, pcb->collection_id-1);
#endif


  /* the roots are:
   *  0. dirty pages not collected in this run
   *  1. the stack
   *  2. the next continuation
   *  3. the oblist
   */
  scan_dirty_pages(&gc);
  collect_stack(&gc, pcb->frame_pointer, pcb->frame_base - wordsize);
  pcb->next_k = add_object(&gc, pcb->next_k, "next_k"); 
  pcb->oblist = add_object(&gc, pcb->oblist, "oblist"); 
  pcb->arg_list = add_object(&gc, pcb->arg_list, "args_list");
  /* now we trace all live objects */
  collect_loop(&gc);

  fix_weak_pointers(&gc);
  /* now deallocate all unused pages */
  deallocate_unused_pages(&gc);

  fix_new_pages(&gc);
  pcb->allocation_pointer = pcb->heap_base;
  gc_add_tconcs(&gc);
  pcb->weak_pairs_ap = 0;
  pcb->weak_pairs_ep = 0;

  if(accounting){
    fprintf(stderr, 
        "[%d cons|%d sym|%d cls|%d vec|%d rec|%d cck|%d str|%d htb]\n",
        pair_count,
        symbol_count,
        closure_count,
        vector_count,
        record_count,
        continuation_count,
        string_count,
        htable_count);
    pair_count = 0;
    symbol_count = 0;
    closure_count = 0;
    vector_count = 0;
    record_count = 0;
    continuation_count = 0;
    string_count = 0;
    htable_count = 0;
  }
  //ik_dump_metatable(pcb);
#ifndef NDEBUG
  fprintf(stderr, "collect done\n");
#endif
  getrusage(RUSAGE_SELF, &t1);
  pcb->collect_utime.tv_usec += t1.ru_utime.tv_usec - t0.ru_utime.tv_usec;
  pcb->collect_utime.tv_sec += t1.ru_utime.tv_sec - t0.ru_utime.tv_sec;
  if (pcb->collect_utime.tv_usec >= 1000000){
   pcb->collect_utime.tv_usec -= 1000000;
   pcb->collect_utime.tv_sec += 1;
  }
  else if (pcb->collect_utime.tv_usec < 0){
   pcb->collect_utime.tv_usec += 1000000;
   pcb->collect_utime.tv_sec -= 1;
  }
 
  pcb->collect_stime.tv_usec += t1.ru_stime.tv_usec - t0.ru_stime.tv_usec;
  pcb->collect_stime.tv_sec += t1.ru_stime.tv_sec - t0.ru_stime.tv_sec;
  if (pcb->collect_stime.tv_usec >= 1000000){
   pcb->collect_stime.tv_usec -= 1000000;
   pcb->collect_stime.tv_sec += 1;
  }
  else if (pcb->collect_stime.tv_usec < 0){
   pcb->collect_stime.tv_usec += 1000000;
   pcb->collect_stime.tv_sec -= 1;
  }
 
  /* delete all old heap pages */
  if(pcb->heap_pages){
    ikpages* p = pcb->heap_pages;
    do{
      ikpages* next = p->next;
      ik_munmap_from_segment(p->base, p->size, pcb);
      ik_free(p, sizeof(ikpages));
      p=next;
    } while(p);
    pcb->heap_pages = 0;
  }

  int free_space = 
    ((unsigned int)pcb->allocation_redline) - 
    ((unsigned int)pcb->allocation_pointer);
  if(free_space <= mem_req){
#ifndef NDEBUG
    fprintf(stderr, "REQ=%d, got %d\n", mem_req, free_space);
#endif
    int memsize = align_to_next_page(mem_req);
    ik_munmap_from_segment(
        pcb->heap_base,
        pcb->heap_size,
        pcb);
    ikp ptr = ik_mmap_mixed(memsize+2*pagesize, pcb);
    pcb->allocation_pointer = ptr;
    pcb->allocation_redline = ptr+memsize;
    pcb->heap_base = ptr;
    pcb->heap_size = memsize+2*pagesize;
  }

  return pcb;
}


#define disp_frame_offset -13
#define disp_multivalue_rp -9


#define CODE_EXTENSION_SIZE (pagesize)

//X static ikp
//X gc_alloc_new_code_extending(int size, int old_gen, gc_t* gc){
//X   int mapsize = align_to_next_page(size);
//X   if(mapsize < CODE_EXTENSION_SIZE){
//X     mapsize = CODE_EXTENSION_SIZE;
//X   }
//X   if(gc->gen[old_gen].code_base){
//X     qupages_t* p = ik_malloc(sizeof(qupages_t));
//X     ikp aq = gc->gen[old_gen].code_aq;
//X     ikp ap = gc->gen[old_gen].code_ap;
//X     ikp ep = gc->gen[old_gen].code_ep;
//X     p->p = aq;
//X     p->q = ap;
//X     p->next = gc->code_queue;
//X     gc->code_queue = p;
//X     ikp x = ap;
//X     while(x < ep){
//X       ref(x, 0) = 0;
//X       x += wordsize;
//X     }
//X   }
//X   ikp mem = ik_mmap_typed(
//X       mapsize, 
//X       code_mt | next_gen_tag[old_gen],
//X       gc->pcb);
//X   gc->segment_vector = gc->pcb->segment_vector;
//X   gc->gen[old_gen].code_ap = mem + size;
//X   gc->gen[old_gen].code_aq = mem;
//X   gc->gen[old_gen].code_ep = mem + mapsize;
//X   gc->gen[old_gen].code_base = mem;
//X   return mem;
//X }
//X 
static int alloc_code_count = 0;


static ikp 
add_code_entry(gc_t* gc, ikp entry){
  ikp x = entry - disp_code_data;
  if(ref(x,0) == forward_ptr){
    return ref(x,wordsize) + off_code_data;
  }
  int idx = page_index(x);
  unsigned int t = gc->segment_vector[idx];
  int gen = t & gen_mask;
  if(gen > gc->collect_gen){
    return entry;
  }
  int code_size = unfix(ref(x, disp_code_code_size));
  ikp reloc_vec = ref(x, disp_code_reloc_vector);
  ikp freevars = ref(x, disp_code_freevars);
  int required_mem = align(disp_code_data + code_size);
  if(required_mem >= pagesize){
    int new_tag = next_gen_tag[gen];
    int idx = page_index(x);
    gc->segment_vector[idx] = new_tag | code_mt;
    int i;
    for(i=pagesize, idx++; i<required_mem; i+=pagesize, idx++){
      gc->segment_vector[idx] = new_tag | data_mt;
    }
    qupages_t* p = ik_malloc(sizeof(qupages_t));
    p->p = x;
    p->q = x+required_mem;
    p->next = gc->queues[meta_code];
    gc->queues[meta_code] = p;
    return entry;
  } else {
    ikp y = gc_alloc_new_code(required_mem, gen, gc);
    ref(y, 0) = code_tag;
    ref(y, disp_code_code_size) = fix(code_size);
    ref(y, disp_code_reloc_vector) = reloc_vec;
    ref(y, disp_code_freevars) = freevars;
    memcpy(y+disp_code_data, x+disp_code_data, code_size);
    ref(x, 0) = forward_ptr;
    ref(x, wordsize) = y + vector_tag;
    return y+disp_code_data;
  }
}


#define DEBUG_STACK 0

static void collect_stack(gc_t* gc, ikp top, ikp end){
  if(DEBUG_STACK){
    fprintf(stderr, "collecting stack from 0x%08x .. 0x%08x\n", 
        (int) top, (int) end);
  }
  while(top < end){
    if(DEBUG_STACK){
      fprintf(stderr, "collecting frame at 0x%08x: ", (int) top);
    }
    ikp rp = ref(top, 0);
    int rp_offset = unfix(ref(rp, disp_frame_offset));
    if(DEBUG_STACK){
      fprintf(stderr, "rp_offset=%d\n", rp_offset);
    }
    if(rp_offset <= 0){
      fprintf(stderr, "invalid rp_offset %d\n", rp_offset);
      exit(-1);
    }
    /* since the return point is alive, we need to find the code
     * object containing it and mark it live as well.  the rp is
     * updated to reflect the new code object. */

    int code_offset = rp_offset - disp_frame_offset;
    ikp code_entry = rp - code_offset;
    ikp new_code_entry = add_code_entry(gc, code_entry);
    ikp new_rp = new_code_entry + code_offset;
    ref(top, 0) = new_rp;

    /* now for some livemask action.
     * every return point has a live mark above it.  the live mask
     * is a sequence of bytes (every byte for 8 frame cells).  the 
     * size of the live mask is determined by the size of the frame.
     * this is how the call frame instruction sequence looks like:
     *
     *   |    ...     |
     *   | code  junk |
     *   +------------+
     *   |   byte 0   |   for fv0 .. fv7
     *   |   byte 1   |   for fv8 .. fv15
     *   |    ...     |   ...
     *   +------------+
     *   |  framesize |
     *   |    word    |
     *   +------------+
     *   | multivalue |
     *   |    word    |
     *   +------------+
     *   | frameoffst |  the frame offset determined how far its
     *   |    word    |  address is off from the start of the code
     *   +------------+
     *   |  padding   |  the size of this part is fixed so that we
     *   |  and call  |  can correlate the frame info (above) with rp
     *   +------------+
     *   | code  junk | <---- rp
     *   |    ...     | 
     *
     *   WITH ONE EXCEPTION:
     *   if the framesize is 0, then the actual frame size is stored
     *   on the stack immediately below the return point.
     *   there is no live mask in this case, instead all values in the
     *   frame are live.
     */
    int framesize = (int) ref(rp, disp_frame_size);
    if(DEBUG_STACK){
      fprintf(stderr, "fs=%d\n", framesize);
    }
    if(framesize < 0){
      fprintf(stderr, "invalid frame size %d\n", framesize);
      exit(-1);
    } 
    else if(framesize == 0){
      framesize = (int)ref(top, wordsize);
      if(framesize <= 0){
        fprintf(stderr, "invalid redirected framesize=%d\n", framesize);
        exit(-1);
      }
      ikp base = top + framesize - wordsize;
      while(base > top){
        ikp new_obj = add_object(gc,ref(base,0), "frame");
        ref(base,0) = new_obj;
        base -= wordsize;
      }
    } else {
      int frame_cells = framesize >> fx_shift;
      int bytes_in_mask = (frame_cells+7) >> 3;
      unsigned char* mask = rp + disp_frame_size  - bytes_in_mask;
  
      ikp* fp = (ikp*)(top + framesize);
      int i;
      for(i=0; i<bytes_in_mask; i++, fp-=8){
        unsigned char m = mask[i];
#if DEBUG_STACK
        fprintf(stderr, "m[%d]=0x%x\n", i, m);
#endif
        if(m & 0x01) { fp[-0] = add_object(gc, fp[-0], "frame0"); }
        if(m & 0x02) { fp[-1] = add_object(gc, fp[-1], "frame1"); }
        if(m & 0x04) { fp[-2] = add_object(gc, fp[-2], "frame2"); }
        if(m & 0x08) { fp[-3] = add_object(gc, fp[-3], "frame3"); }
        if(m & 0x10) { fp[-4] = add_object(gc, fp[-4], "frame4"); }
        if(m & 0x20) { fp[-5] = add_object(gc, fp[-5], "frame5"); }
        if(m & 0x40) { fp[-6] = add_object(gc, fp[-6], "frame6"); }
        if(m & 0x80) { fp[-7] = add_object(gc, fp[-7], "frame7"); }
      }
    }
    top += framesize;
  }
  if(top != end){
    fprintf(stderr, "frames did not match up 0x%08x .. 0x%08x\n",
        (int) top, (int) end);
    exit(-1);
  }
  if(DEBUG_STACK){
    fprintf(stderr, "done with stack!\n");
  }
}


static void 
add_list(gc_t* gc, unsigned int t, int gen, ikp x, ikp* loc){
  int collect_gen = gc->collect_gen;
  while(1){
    ikp fst = ref(x, off_car);
    ikp snd = ref(x, off_cdr);
    ikp y;
    if((t & type_mask) != weak_pairs_type){
      y = gc_alloc_new_pair(gen, gc) + pair_tag;
    } else {
      y = gc_alloc_new_weak_pair(gen, gc) + pair_tag;
    }
    *loc = y;
    ref(x,off_car) = forward_ptr;
    ref(x,off_cdr) = y;
    ref(y,off_car) = fst;
    int stag = tagof(snd);
    if(stag == pair_tag){
      if(ref(snd, -pair_tag) == forward_ptr){
        ref(y, off_cdr) = ref(snd, wordsize-pair_tag);
        return;
      } 
      else {
        t = gc->segment_vector[page_index(snd)];
        gen = t & gen_mask;
        if(gen > collect_gen){
          ref(y, off_cdr) = snd;
          return;
        } else {
          x = snd;
          loc = (ikp*)(y + off_cdr);
          /* don't return */
        }
      }
    }
    else if(   (stag == immediate_tag)
            || (stag == 0) 
            || (stag == (1<<fx_shift))) {
      ref(y,off_cdr) = snd;
      return;
    }
    else if (ref(snd, -stag) == forward_ptr){
      ref(y, off_cdr) = ref(snd, wordsize-stag);
      return;
    }
    else {
      ref(y, off_cdr) = add_object(gc, snd, "add_list");
      return;
    }
  }
}


static ikp 
add_object(gc_t* gc, ikp x, char* caller){
  if(is_fixnum(x)){ 
    return x;
  } 
  if(x == forward_ptr){
    fprintf(stderr, "GOTCHA\n");
    exit(-1);
  }
  int tag = tagof(x);
  if(tag == immediate_tag){
    return x;
  }
  ikp fst = ref(x, -tag);
  if(fst == forward_ptr){
    /* already moved */
    return ref(x, wordsize-tag);
  }
  unsigned int t = gc->segment_vector[page_index(x)];
  int gen = t & gen_mask;
  if(gen > gc->collect_gen){
    return x;
  }
  if(tag == pair_tag){
    ikp y;
    add_list(gc, t, gen, x, &y);
    return y;
  }
  else if(tag == symbol_tag){
    ikp y = gc_alloc_new_ptr(symbol_size, gen, gc) + symbol_tag;
    ref(y, off_symbol_string) = ref(x, off_symbol_string);
    ref(y, off_symbol_ustring) = ref(x, off_symbol_ustring);
    ref(y, off_symbol_value) = ref(x, off_symbol_value);
    ref(y, off_symbol_plist) = ref(x, off_symbol_plist);
    ref(y, off_symbol_system_value) = ref(x, off_symbol_system_value);
    ref(y, off_symbol_system_plist) = ref(x, off_symbol_system_plist);
    ref(x, -symbol_tag) = forward_ptr;
    ref(x, wordsize-symbol_tag) = y;
    if(accounting){
      symbol_count++;
    }
    return y;
  }
  else if(tag == closure_tag){
    int size = disp_closure_data+
              (int) ref(fst, disp_code_freevars - disp_code_data);
    if(size > 1024){
      fprintf(stderr, "large closure size=0x%08x\n", size);
    }
    int asize = align(size);
    ikp y = gc_alloc_new_ptr(asize, gen, gc) + closure_tag;
    ref(y, asize-closure_tag-wordsize) = 0;
    memcpy(y-closure_tag, x-closure_tag, size);
    ref(y,-closure_tag) = add_code_entry(gc, ref(y,-closure_tag));
    ref(x,-closure_tag) = forward_ptr;
    ref(x,wordsize-closure_tag) = y;
    if(accounting){
      closure_count++;
    }
    return y;
  }
  else if(tag == vector_tag){
    if(is_fixnum(fst)){
      /* real vector */
      int size = (int)fst;
      assert(size >= 0);
      int memreq = align(size + disp_vector_data);
      ikp y = gc_alloc_new_ptr(memreq, gen, gc) + vector_tag;
      ref(y, disp_vector_length-vector_tag) = fst;
      ref(y, memreq-vector_tag-wordsize) = 0;
      memcpy(y+off_vector_data, x+off_vector_data, size);
      ref(x,-vector_tag) = forward_ptr;
      ref(x,wordsize-vector_tag) = y;
      if(accounting){
        vector_count++;
      }
      return y;
    } 
    else if(tagof(fst) == rtd_tag){
      /* record */
      int size = (int) ref(fst, off_rtd_length);
      if(size > 4096){
        fprintf(stderr, "large rec size=0x%08x\n", size);
      }
      int memreq = align(size + disp_record_data);
      ikp y = gc_alloc_new_ptr(memreq, gen, gc) + vector_tag;
      ref(y, memreq-vector_tag-wordsize) = 0;
      memcpy(y-vector_tag, x-vector_tag, size+wordsize);
      ref(x,-vector_tag) = forward_ptr;
      ref(x,wordsize-vector_tag) = y;
      if(accounting){
        record_count++;
      }
      return y;
    }
    else if(fst == code_tag){
      ikp entry = x + off_code_data;
      ikp new_entry = add_code_entry(gc, entry);
      return new_entry - off_code_data;
    } 
    else if(fst == continuation_tag){
      ikp top = ref(x, off_continuation_top);
      int size = (int) ref(x, off_continuation_size);
#ifndef NDEBUG
      if(size > 4096){
        fprintf(stderr, "large cont size=0x%08x\n", size);
      }
#endif
      ikp next = ref(x, off_continuation_next);
      ikp y = gc_alloc_new_ptr(continuation_size, gen, gc) + vector_tag;
      ref(x, -vector_tag) = forward_ptr;
      ref(x, wordsize-vector_tag) = y;
      ikp new_top = gc_alloc_new_data(align(size), gen, gc);
      memcpy(new_top, top, size);
      collect_stack(gc, new_top, new_top + size);
      ref(y, -vector_tag) = continuation_tag;
      ref(y, off_continuation_top) = new_top;
      ref(y, off_continuation_size) = (ikp) size;
      ref(y, off_continuation_next) = next;
      if(accounting){
        continuation_count++;
      }
      return y;
    }
    else if(tagof(fst) == pair_tag){
      /* tcbucket */
      ikp y = gc_alloc_new_ptr(tcbucket_size, gen, gc) + vector_tag;
      ref(y,off_tcbucket_tconc) = fst;
      ikp key = ref(x, off_tcbucket_key);
      ref(y,off_tcbucket_key) = key;
      ref(y,off_tcbucket_val) = ref(x, off_tcbucket_val);
      ref(y,off_tcbucket_next) = ref(x, off_tcbucket_next);
      ref(y,off_tcbucket_dlink_next) = ref(x, off_tcbucket_dlink_next);
      ref(y,off_tcbucket_dlink_prev) = ref(x, off_tcbucket_dlink_prev);
      if((! is_fixnum(key)) && (tagof(key) != immediate_tag)){
        unsigned int kt = gc->segment_vector[page_index(key)];
        if((kt & gen_mask) <= gc->collect_gen){
          /* key is moved */
          gc_tconc_push(gc, y);
        }
      }
      ref(x, -vector_tag) = forward_ptr;
      ref(x, wordsize-vector_tag) = y;
      return y;
    }
    else if((((int)fst) & port_mask) == port_tag){
      ikp y = gc_alloc_new_ptr(port_size, gen, gc) + vector_tag;
      ref(y, -vector_tag) = fst;
      int i;
      for(i=wordsize; i<port_size; i+=wordsize){
        ref(y, i-vector_tag) = ref(x, i-vector_tag);
      }
      ref(x, -vector_tag) = forward_ptr;
      ref(x, wordsize-vector_tag) = y;
      return y;
    }
    else if((((int)fst) & bignum_mask) == bignum_tag){
      int len = ((unsigned int)fst) >> bignum_length_shift;
      int memreq = align(disp_bignum_data + len*wordsize);
      ikp new = gc_alloc_new_data(memreq, gen, gc) + vector_tag;
      memcpy(new-vector_tag, x, memreq);
      ref(x, 0) = forward_ptr;
      ref(x, wordsize) = new;
      return new;
    }
    else {
      fprintf(stderr, "unhandled vector with fst=0x%08x\n", (int)fst);
      exit(-1);
    }
  }
  else if(tag == string_tag){
    if(is_fixnum(fst)){
      int strlen = unfix(fst);
      int memreq = align(strlen + disp_string_data + 1);
      ikp new_str = gc_alloc_new_data(memreq, gen, gc) + string_tag;
      ref(new_str, off_string_length) = fst;
      memcpy(new_str+off_string_data,
             x + off_string_data,
             strlen + 1);
      ref(x, -string_tag) = forward_ptr;
      ref(x, wordsize-string_tag) = new_str;
      if(accounting){
        string_count++;
      }
      return new_str;
    }
    else {
      fprintf(stderr, "unhandled string 0x%08x with fst=0x%08x\n",
          (int)x, (int)fst);
      exit(-1);
    }
  }
  fprintf(stderr, "unhandled tag: %d\n", tag);
  exit(-1);
}

static void
relocate_new_code(ikp x, gc_t* gc){
  ikp relocvector = ref(x, disp_code_reloc_vector);
  relocvector = add_object(gc, relocvector, "reloc");
  ref(x, disp_code_reloc_vector) = relocvector;
  int relocsize = (int)ref(relocvector, off_vector_length);
  ikp p = relocvector + off_vector_data;
  ikp q = p + relocsize;
  ikp code = x + disp_code_data;
  while(p < q){
    int r = unfix(ref(p, 0));
    int tag = r & 3;
    int code_off = r >> 2;
    if(tag == 0){
      /* undisplaced pointer */
      ikp old_object = ref(p, wordsize);
      ikp new_object = add_object(gc, old_object, "reloc");
      ref(code, code_off) = new_object;
      p += (2*wordsize);
    }
    else if(tag == 2){
      /* displaced pointer */
      int obj_off = unfix(ref(p, wordsize));
      ikp old_object = ref(p, 2*wordsize);
      ikp new_object = add_object(gc, old_object, "reloc");
      ref(code, code_off) = new_object + obj_off;
      p += (3 * wordsize);
    } 
    else if(tag == 3){
      /* displaced relative pointer */
      int obj_off = unfix(ref(p, wordsize));
      ikp obj = add_object(gc, ref(p, 2*wordsize), "reloc");
      ikp displaced_object = obj + obj_off;
      ikp next_word = code + code_off + wordsize;
      ikp relative_distance = displaced_object - (int)next_word;
      ref(next_word, -wordsize) = relative_distance;
      p += (3*wordsize);
    }
    else if(tag == 1){
      /* do nothing */
      p += (2 * wordsize);
    }
    else {
      fprintf(stderr, "invalid rtag %d in 0x%08x\n", tag, r);
      exit(-1);
    } 
  }
}



static void 
collect_loop(gc_t* gc){
  int done;
  do{
    done = 1;
    { /* scan the pending pairs pages */
      qupages_t* qu = gc->queues[meta_pair];
      if(qu){
        done = 0;
        gc->queues[meta_pair] = 0;
        do{
          ikp p = qu->p;
          ikp q = qu->q;
          while(p < q){
            ref(p,0) = add_object(gc, ref(p,0), "loop");
            p += (2*wordsize);
          }
          qupages_t* next = qu->next;
          ik_free(qu, sizeof(qupages_t));
          qu = next;
        } while(qu);
      }
    }

    { /* scan the pending pointer pages */
      qupages_t* qu = gc->queues[meta_ptrs];
      if(qu){
        done = 0;
        gc->queues[meta_ptrs] = 0;
        do{
          ikp p = qu->p;
          ikp q = qu->q;
          while(p < q){
            ref(p,0) = add_object(gc, ref(p,0), "pending");
            p += wordsize;
          }
          qupages_t* next = qu->next;
          ik_free(qu, sizeof(qupages_t));
          qu = next;
        } while(qu);
      }
    }
    { /* scan the pending code objects */
      qupages_t* codes = gc->queues[meta_code];
      if(codes){
        gc->queues[meta_code] = 0;
        done = 0;
        do{
          ikp p = codes->p;
          ikp q = codes->q;
          while(p < q){
            relocate_new_code(p, gc);
            alloc_code_count--;
            p += align(disp_code_data + unfix(ref(p, disp_code_code_size))); 
          }
          qupages_t* next = codes->next;
          ik_free(codes, sizeof(qupages_t));
          codes = next;
        } while(codes);
      }
    }
    {/* see if there are any remaining in the main ptr segment */
      int i;
      for(i=0; i<=gc->collect_gen; i++){
        meta_t* meta = &gc->meta[i][meta_pair];
        ikp p = meta->aq;
        ikp q = meta->ap;
        if(p < q){
          done = 0;
          do{
            meta->aq = q;
            while(p < q){
              ref(p,0) = add_object(gc, ref(p,0), "rem");
              p += (2*wordsize);
            }
            p = meta->aq;
            q = meta->ap;
          } while (p < q);
        }
      }
      for(i=0; i<=gc->collect_gen; i++){
        meta_t* meta = &gc->meta[i][meta_ptrs];
        ikp p = meta->aq;
        ikp q = meta->ap;
        if(p < q){
          done = 0;
          do{
            meta->aq = q;
            while(p < q){
              ref(p,0) = add_object(gc, ref(p,0), "rem2");
              p += wordsize;
            }
            p = meta->aq;
            q = meta->ap;
          } while (p < q);
        }
      }
      for(i=0; i<=gc->collect_gen; i++){
        meta_t* meta = &gc->meta[i][meta_code];
        ikp p = meta->aq;
        ikp q = meta->ap;
        if(p < q){
          done = 0;
          do{
            meta->aq = q;
            do{
              alloc_code_count--;
              relocate_new_code(p, gc);
              p += align(disp_code_data + unfix(ref(p, disp_code_code_size)));
            } while (p < q);
            p = meta->aq;
            q = meta->ap;
          } while (p < q);
        }
      }
    }
    /* phew */
  } while (! done);
  {
    int i;
    for(i=0; i<=gc->collect_gen; i++){
      meta_t* meta = &gc->meta[i][meta_pair];
      ikp p = meta->ap;
      ikp q = meta->ep;
      while(p < q){
        ref(p, 0) = 0;
        p += wordsize;
      }
    }
    for(i=0; i<=gc->collect_gen; i++){
      meta_t* meta = &gc->meta[i][meta_ptrs];
      ikp p = meta->ap;
      ikp q = meta->ep;
      while(p < q){
        ref(p, 0) = 0;
        p += wordsize;
      }
    }
    for(i=0; i<=gc->collect_gen; i++){
      meta_t* meta = &gc->meta[i][meta_weak];
      ikp p = meta->ap;
      ikp q = meta->ep;
      while(p < q){
        ref(p, 0) = 0;
        p += wordsize;
      }
    }
    for(i=0; i<=gc->collect_gen; i++){
      meta_t* meta = &gc->meta[i][meta_code];
      ikp p = meta->ap;
      ikp q = meta->ep;
      while(p < q){
        ref(p, 0) = 0;
        p += wordsize;
      }
    }
  }
}

static void
fix_weak_pointers(gc_t* gc){
  unsigned int* segment_vec = gc->segment_vector;
  ikpcb* pcb = gc->pcb;
  int lo_idx = page_index(pcb->memory_base);
  int hi_idx = page_index(pcb->memory_end);
  int i = lo_idx;
  int collect_gen = gc->collect_gen;
  while(i < hi_idx){
    unsigned int t = segment_vec[i];
    if((t & type_mask) == weak_pairs_type){
      int gen = t & gen_mask;
      if(gen > collect_gen){
        ikp p = (ikp)(i << pageshift);
        ikp q = p + pagesize;
        while(p < q){
          ikp x = ref(p, 0);
          if(! is_fixnum(x)){
            int tag = tagof(x);
            if(tag != immediate_tag){
              ikp fst = ref(x, -tag);
              if(fst == forward_ptr){
                ref(p, 0) = ref(x, wordsize-tag); } 
              else {
                int x_gen = segment_vec[page_index(x)] & gen_mask;
                if(x_gen <= collect_gen){
                  ref(p, 0) = bwp_object; } } } }
          p += (2*wordsize); } } }
    i++; } }

static unsigned int dirty_mask[generation_count] = {
  0x88888888,
  0xCCCCCCCC,
  0xEEEEEEEE,
  0xFFFFFFFF,
  0x00000000
};


static unsigned int cleanup_mask[generation_count] = {
  0x00000000,
  0x88888888,
  0xCCCCCCCC,
  0xEEEEEEEE,
  0xFFFFFFFF
};



static void 
scan_dirty_pointers_page(gc_t* gc, int page_idx, int mask){
  unsigned int* segment_vec = gc->segment_vector;
  unsigned int* dirty_vec = gc->pcb->dirty_vector;
  unsigned int t = segment_vec[page_idx];
  unsigned int d = dirty_vec[page_idx];
  unsigned int masked_d = d & mask;
  ikp p = (ikp)(page_idx << pageshift);
  int j;
  unsigned int new_d = 0;
  for(j=0; j<cards_per_page; j++){
    if(masked_d & (0xF << (j*meta_dirty_shift))){
      /* dirty card */
      ikp q = p + cardsize;
      unsigned int card_d = 0;
      while(p < q){
        ikp x = ref(p, 0);
        if(is_fixnum(x) || (tagof(x) == immediate_tag)){
          /* do nothing */
        } else {
          ikp y = add_object(gc, x, "nothing");
          segment_vec = gc->segment_vector;
          ref(p, 0) = y;
          card_d = card_d | segment_vec[page_index(y)];
        }
        p += wordsize;
      }
      card_d = (card_d & meta_dirty_mask) >> meta_dirty_shift;
      new_d = new_d | (card_d<<(j*meta_dirty_shift));
    } else {
      p += cardsize;
      new_d = new_d | (d & (0xF << (j*meta_dirty_shift)));
    }
  }
  dirty_vec = gc->pcb->dirty_vector;
  new_d = new_d & cleanup_mask[t & gen_mask];
  dirty_vec[page_idx] = new_d;
}

static void            
scan_dirty_code_page(gc_t* gc, int page_idx, unsigned int mask){
  ikp p = (ikp)(page_idx << pageshift);
  ikp start = p;
  ikp q = p + pagesize;
  unsigned int* segment_vec = gc->segment_vector;
  unsigned int* dirty_vec = gc->pcb->dirty_vector;
  //unsigned int d = dirty_vec[page_idx];
  unsigned int t = segment_vec[page_idx];
  //unsigned int masked_d = d & mask;
  unsigned int new_d = 0;
  while(p < q){
    if(ref(p, 0) != code_tag){
      p = q;
    } 
    else {
      int j = ((int)p - (int)start) / cardsize;
      int code_size = unfix(ref(p, disp_code_code_size));
      relocate_new_code(p, gc);
      segment_vec = gc->segment_vector;
      ikp rvec = ref(p, disp_code_reloc_vector);
      int len = (int)ref(rvec, off_vector_length);
      assert(len >= 0);
      int i;
      unsigned int code_d = segment_vec[page_index(rvec)];
      for(i=0; i<len; i+=wordsize){
        ikp r = ref(rvec, i+off_vector_data);
        if(is_fixnum(r) || (tagof(r) == immediate_tag)){
          /* do nothing */
        } else {
          r = add_object(gc, r, "nothing2");
          segment_vec = gc->segment_vector;
          code_d = code_d | segment_vec[page_index(r)];
        }
      }
      new_d = new_d | (code_d<<(j*meta_dirty_shift));
      p += align(code_size + disp_code_data);
    }
  }
  dirty_vec = gc->pcb->dirty_vector;
  new_d = new_d & cleanup_mask[t & gen_mask];
  dirty_vec[page_idx] = new_d;
}

/* scanning dirty weak pointers should add the cdrs of the pairs
 * but leave the cars unmodified.  The dirty mask is also kept 
 * unmodified so that the after-pass fixes it.
 */

static void 
scan_dirty_weak_pointers_page(gc_t* gc, int page_idx, int mask){
  unsigned int* dirty_vec = gc->pcb->dirty_vector;
  unsigned int d = dirty_vec[page_idx];
  unsigned int masked_d = d & mask;
  ikp p = (ikp)(page_idx << pageshift);
  int j;
  for(j=0; j<cards_per_page; j++){
    if(masked_d & (0xF << (j*meta_dirty_shift))){
      /* dirty card */
      ikp q = p + cardsize;
      while(p < q){
        ikp x = ref(p, wordsize);
        if(is_fixnum(x) || tagof(x) == immediate_tag){
          /* do nothing */
        } else {
          ikp y = add_object(gc, x, "nothing3");
          ref(p, wordsize) = y;
        }
        p += (2*wordsize);
      }
    } else {
      p += cardsize;
    }
  }
}





static void
scan_dirty_pages(gc_t* gc){
  ikpcb* pcb = gc->pcb;
  int lo_idx = page_index(pcb->memory_base);
  int hi_idx = page_index(pcb->memory_end);
  unsigned int* dirty_vec = pcb->dirty_vector;
  unsigned int* segment_vec = pcb->segment_vector;
  int collect_gen = gc->collect_gen;
  unsigned int mask = dirty_mask[collect_gen];
  int i = lo_idx;
  while(i < hi_idx){
    unsigned int d = dirty_vec[i];
    if(d & mask){
      unsigned int t = segment_vec[i];
      if((t & gen_mask) > collect_gen){
        int type = t & type_mask;
        if(type == pointers_type){
          scan_dirty_pointers_page(gc, i, mask);
          dirty_vec = pcb->dirty_vector;
          segment_vec = pcb->segment_vector;
        }
        else if (type == weak_pairs_type){
          if((t & gen_mask) > collect_gen){
            scan_dirty_weak_pointers_page(gc, i, mask);
            dirty_vec = pcb->dirty_vector;
            segment_vec = pcb->segment_vector;
          }
        }
        else if (type == code_type){
          if((t & gen_mask) > collect_gen){
            scan_dirty_code_page(gc, i, mask);
            dirty_vec = pcb->dirty_vector;
            segment_vec = pcb->segment_vector;
          }
        }
        else if (t & scannable_mask) {
          fprintf(stderr, "BUG: unhandled scan of type 0x%08x\n", t);
          exit(-1);
        }
      }
    }
    i++;
  }
}




static void
deallocate_unused_pages(gc_t* gc){
  ikpcb* pcb = gc->pcb;
  int collect_gen =  gc->collect_gen;
  unsigned int* segment_vec = pcb->segment_vector;
  unsigned char* memory_base = pcb->memory_base;
  unsigned char* memory_end = pcb->memory_end;
  int lo_idx = page_index(memory_base);
  int hi_idx = page_index(memory_end);
  int i = lo_idx;
  while(i < hi_idx){
    unsigned int t = segment_vec[i];
    if(t & dealloc_mask){
      int gen = t & old_gen_mask;
      if(gen <= collect_gen){
        /* we're interested */
        if(t & new_gen_mask){
          /* do nothing yet */
        } else {
          ik_munmap_from_segment((unsigned char*)(i<<pageshift),pagesize,pcb);
        }
      }
    }
    i++;
  }
}


static void
fix_new_pages(gc_t* gc){
  ikpcb* pcb = gc->pcb;
  unsigned int* segment_vec = pcb->segment_vector;
  unsigned int* dirty_vec = pcb->dirty_vector;
  unsigned char* memory_base = pcb->memory_base;
  unsigned char* memory_end = pcb->memory_end;
  int lo_idx = page_index(memory_base);
  int hi_idx = page_index(memory_end);
  int i = lo_idx;
  while(i < hi_idx){
    unsigned int t = segment_vec[i];
    if((t & new_gen_mask) ||
       ((t & type_mask) == weak_pairs_type)){
      segment_vec[i] = t & ~new_gen_mask;
      int page_gen = t & old_gen_mask;
      if(((t & type_mask) == pointers_type) ||
         ((t & type_mask) == weak_pairs_type)){
        ikp p = (ikp)(i << pageshift);
        unsigned int d = 0;
        int j;
        for(j=0; j<cards_per_page; j++){
          ikp q = p + cardsize;
          unsigned int card_d = 0;
          while(p < q){
            ikp x = ref(p, 0);
            if(is_fixnum(x) || (tagof(x) == immediate_tag)){
              /* nothing */
            } else {
              card_d = card_d | segment_vec[page_index(x)];
            }
            p += wordsize;
          }
          card_d = (card_d & meta_dirty_mask) >> meta_dirty_shift;
          d = d | (card_d<<(j*meta_dirty_shift));
        }
        dirty_vec[i] = d & cleanup_mask[page_gen];
      } 
      else if((t & type_mask) == code_type){
        /* FIXME: scan codes */
        ikp page_base = (ikp)(i << pageshift);
        ikp p = page_base;
        ikp q = p + pagesize;
        int err = mprotect(page_base, pagesize, PROT_READ|PROT_WRITE|PROT_EXEC);
        if(err){
          fprintf(stderr, "cannot protect code page: %s\n", strerror(errno));
          exit(-1);
        }
        unsigned int d = 0;
        while(p < q){
          if(ref(p, 0) != code_tag){
            p = q;
          }
          else {
            ikp rvec = ref(p, disp_code_reloc_vector);
            int size = (int)ref(rvec, off_vector_length);
            ikp vp = rvec + off_vector_data;
            ikp vq = vp + size;
            unsigned int code_d = segment_vec[page_index(rvec)];
            while(vp < vq){
              ikp x = ref(vp, 0);
              if(is_fixnum(x) || (tagof(x) == immediate_tag)){
                /* do nothing */
              } else {
                code_d = code_d || segment_vec[page_index(x)];
              }
              vp += wordsize;
            }
            code_d = (code_d & meta_dirty_mask) >> meta_dirty_shift;
            int j = ((int)p - (int)page_base)/cardsize;
            d = d | (code_d<<(j*meta_dirty_shift));
            p += align(disp_code_data + unfix(ref(p, disp_code_code_size)));
          }
        }
        dirty_vec[i] = d & cleanup_mask[page_gen];
      }
      else {
        if(t & scannable_mask){
          fprintf(stderr, "unscanned 0x%08x\n", t);
          exit(-1);
        }
      }
    }
    i++;
  }
} 

static void
add_one_tconc(ikpcb* pcb, ikp tcbucket){
  ikp tc = ref(tcbucket, off_tcbucket_tconc);
  assert(tagof(tc) == pair_tag);
  ikp d = ref(tc, off_cdr);
  assert(tagof(d) == pair_tag);
  ikp new_pair = ik_alloc(pcb, pair_size) + pair_tag;
  ref(d, off_car) = tcbucket;
  ref(d, off_cdr) = new_pair;
  ref(new_pair, off_car) = false_object;
  ref(new_pair, off_cdr) = false_object;
  ref(tc, off_cdr) = new_pair;
  ref(tcbucket, -vector_tag) = (ikp)(tcbucket_size - wordsize);
  pcb->dirty_vector[page_index(tc)] = -1;
  pcb->dirty_vector[page_index(d)] = -1;
}

static void
gc_add_tconcs(gc_t* gc){
  if(gc->tconc_base == 0){
    return;
  }
  ikpcb* pcb = gc->pcb;
  {
    ikp p = gc->tconc_base;
    ikp q = gc->tconc_ap;
    while(p < q){
      add_one_tconc(pcb, ref(p,0));
      p += wordsize;
    }
  }
  ikpages* qu = gc->tconc_queue;
  while(qu){
    ikp p = qu->base;
    ikp q = p + qu->size;
    while(p < q){
      add_one_tconc(pcb, ref(p,0));
      p += wordsize;
    }
    ikpages* next = qu->next;
    ik_free(qu, sizeof(ikpages));
    qu = next;
  }
}

