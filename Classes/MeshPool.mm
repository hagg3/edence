//
//  MeshPool.mm
//  Eden — B3 Stage 2: the off-thread mesher's worker pool.  See MeshPool.h for the contract and
//  WORKING/b3-off-thread-meshing-plan.md §4 for the design this implements.
//
//  This file is deliberately small and deliberately boring. All of the hard thinking is in Stage 1
//  (Classes/TerrainChunk.{h,mm}, which made rebuild2() re-entrant) and in the invalidation rules
//  below; what is left is a bounded slot pool, a queue, and two threads.
//
//  NOTE ON THE BUILD: this file is an engine file added AFTER the 2.1.1 import, so it is not in
//  Eden.xcodeproj and web/tools/gen-source-list.sh (which reads that project file) cannot know
//  about it. web/CMakeLists.txt therefore appends it to EDEN_ENGINE_SOURCES explicitly rather than
//  it going in tools/engine-sources.txt, where regenerating the list would silently drop it. The
//  legacy iOS target does not build this file and does not build Terrain.mm's calls into it.
//
#import "MeshPool.h"
#import "Terrain.h"
#import "World.h"

#include <string.h>
#include <sys/time.h>

#ifdef EDEN_THREADED
#include <pthread.h>
#include <sched.h>
#endif

extern TerrainChunk** chunkTablec;
extern BurnNode* burnList;

// How many chunk meshes may be in flight at once. INVARIANT: keep this comfortably above
// BULK_RELOAD_CHUNK_BUDGET (Terrain.mm, 96), or a single frame's dispatch exhausts the pool and
// the tail of it spills to inline meshing -- harmless (that is kill switch 2 doing its job) but it
// quietly puts the work back on the main thread, which is the thing being measured. Observed
// during the Stage 2 budget sweep: budget 144 against 128 slots meshed 301 of 6480 chunks inline.
// The plan doc's R2 also asks for the pool to be deliberately oversubscribed, because "a chunk
// recycled under a running job" is the failure that will not reproduce if the dispatch is always
// tiny. 8 KB of snapshot per slot, so this is 2 MB of steady-state memory.
#define MP_JOB_SLOTS   256
// Two. The mesh is ~half the burst CPU and the main thread still has the other half (column
// decode) to do, so more workers would mostly contend for memory bandwidth; and the Emscripten
// pthread pool has to hold the world-load thread too.
#define MP_WORKERS     2
// Per-job MeshSideEffect capacity. A chunk with more than this many portal tops / corrupt block
// bytes drops the excess, which Stage 1 already documented as survivable (a missed portal
// re-registers on the chunk's next rebuild).
#define MP_SINK_MAX    64
// Above this many simultaneously-burning blocks we stop dispatching for the frame rather than
// grow the per-frame burn snapshot. Fire is a near-the-player, edit-shaped event; a bulk reload
// with hundreds of blocks alight is not a case worth optimising, and meshing inline is correct.
#define MP_BURN_MAX    128

typedef struct _mesh_job{
    TerrainChunk* chunk;
    int idxn;
    // The whole snapshot the plan doc's §2 audit says a worker needs: the chunk's OWN voxels, and
    // nothing else. Every genuinely-shared neighbour read inside rebuild2() funnels through
    // face_visibility[], which is private scratch computed before both the counting and the fill
    // pass, so staleness there is cosmetic and cannot break the count/fill invariant.
    block8 blocks[CHUNK_SIZE3];
    color8 colors[CHUNK_SIZE3];
    MeshSideEffect sink[MP_SINK_MAX];
    int sink_count;
    int result;
}MeshJob;

// "Nothing in this chunk is burning." rebuild2() must be given a mask rather than NULL on a
// worker: NULL means "ask isOnFire()", and isOnFire() walks burnList. Shared, read-only, zero.
static const unsigned char g_no_burn[CHUNK_SIZE3]={0};

static double mp_now(){
    struct timeval tv;
    gettimeofday(&tv,NULL);
    return (double)tv.tv_sec*1000.0+(double)tv.tv_usec/1000.0;
}

// ---- stats (measurement only; see MeshPool.h) --------------------------------------------------
static double   g_snapshotMs=0.0;
static unsigned g_dispatched=0;
static unsigned g_inlined=0;
static unsigned g_published=0;
static unsigned g_stale=0;

extern "C" void mp_getStats(double* snapshotMs,unsigned* dispatched,unsigned* inlined,
                            unsigned* published,unsigned* stale){
    if(snapshotMs)*snapshotMs=g_snapshotMs;
    if(dispatched)*dispatched=g_dispatched;
    if(inlined)*inlined=g_inlined;
    if(published)*published=g_published;
    if(stale)*stale=g_stale;
}
extern "C" void mp_resetStats(){
    g_snapshotMs=0.0;
    g_dispatched=g_inlined=g_published=g_stale=0;
}

#ifndef EDEN_THREADED
// ---------------------------------------------------------------------------------------------
// Kill switch 1: no threads in this build. Every entry point is inert and mp_dispatch() always
// says "mesh it yourself", which is the stock single-threaded path, unchanged.
// ---------------------------------------------------------------------------------------------
void mp_beginFrame(){}
BOOL mp_dispatch(TerrainChunk* chunk,int idxn){ (void)chunk;(void)idxn; g_inlined++; return FALSE; }
void mp_publishFinished(void (*redirty)(int)){ (void)redirty; }
BOOL mp_chunkBusy(const TerrainChunk* chunk){ (void)chunk; return FALSE; }
BOOL mp_columnBusy(int cx,int cz){ (void)cx;(void)cz; return FALSE; }
void mp_drain(void (*redirty)(int),BOOL publish){ (void)redirty;(void)publish; }

#else
// ---------------------------------------------------------------------------------------------
// The real pool.
// ---------------------------------------------------------------------------------------------
static pthread_mutex_t g_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_work=PTHREAD_COND_INITIALIZER;

static MeshJob g_jobs[MP_JOB_SLOTS];
static int g_free_slots[MP_JOB_SLOTS];
static int g_nfree=0;
static int g_queue[MP_JOB_SLOTS];
static int g_qhead=0,g_qtail=0,g_qcount=0;
static int g_done[MP_JOB_SLOTS];
static int g_ndone=0;
static BOOL g_started=FALSE;
static BOOL g_start_failed=FALSE;
// Incremented by each worker the first time it actually RUNS. pthread_create() succeeding is not
// the same as a thread existing here: Emscripten backs a thread with a Worker, and if the pthread
// pool is empty the start is deferred to the next event-loop turn. Queueing work to a pool that
// has not proven it runs would stall the whole bulk reload -- every dispatched chunk stays busy, so
// its column cannot be read either -- so mp_dispatch() waits for this to be nonzero and meshes
// inline until then. Costs at most one frame of ordinary inline meshing, once per session.
static int g_live=0;

// Per-frame burn snapshot (see MP_BURN_MAX). count<0 means "too much fire, dispatch nothing".
typedef struct{int x,y,z;}BurnPos;
static BurnPos g_burn[MP_BURN_MAX];
static int g_burn_count=0;

static void* mp_worker(void* arg){
    (void)arg;
    __atomic_fetch_add(&g_live,1,__ATOMIC_RELEASE);
    for(;;){
        pthread_mutex_lock(&g_lock);
        while(g_qcount==0)
            pthread_cond_wait(&g_work,&g_lock);
        int slot=g_queue[g_qhead];
        g_qhead=(g_qhead+1)%MP_JOB_SLOTS;
        g_qcount--;
        pthread_mutex_unlock(&g_lock);

        MeshJob* j=&g_jobs[slot];
        __atomic_store_n(&j->chunk->meshJobState,MESH_JOB_RUNNING,__ATOMIC_RELAXED);

        // Stage 1's hooks. The source is thread-local, so installing it here affects only this
        // worker's rebuild2() -- the main thread meshing inline at the same moment still reads
        // the chunk's own pblocks/pcolors and still walks burnList, exactly as it always did.
        tc_meshSetSource(j->blocks,j->colors,g_no_burn,j->sink,MP_SINK_MAX,&j->sink_count);
        j->result=j->chunk->rebuild2();
        tc_meshClearSource();

        // RELEASE, paired with the ACQUIRE in mp_publishFinished. Without it the vertex buffer
        // could become visible to the main thread before the counts that describe it -- the plan
        // doc's R3, and the one ordering bug in this design that would corrupt rather than glitch.
        // (The mutex below would supply the same happens-before; this is the documented barrier.)
        __atomic_store_n(&j->chunk->meshJobState,MESH_JOB_DONE,__ATOMIC_RELEASE);

        pthread_mutex_lock(&g_lock);
        g_done[g_ndone++]=slot;
        pthread_mutex_unlock(&g_lock);
    }
    return NULL;
}

// Lazy, once. Returns FALSE if the threads could not be created, in which case every dispatch
// falls back to meshing inline for the rest of the session -- degraded, never broken.
static BOOL mp_start(){
    if(g_started)return TRUE;
    if(g_start_failed)return FALSE;
    if(MP_JOB_SLOTS<=0){g_start_failed=TRUE;return FALSE;}

    for(int i=0;i<MP_JOB_SLOTS;i++)g_free_slots[i]=i;
    g_nfree=MP_JOB_SLOTS;

    int made=0;
    for(int i=0;i<MP_WORKERS;i++){
        pthread_t t;
        if(pthread_create(&t,NULL,mp_worker,NULL)==0){
            pthread_detach(t);
            made++;
        }
    }
    if(made==0){
        printg("MeshPool: no worker threads could be created, meshing stays inline\n");
        g_start_failed=TRUE;
        return FALSE;
    }
    printg("MeshPool: %d worker(s), %d job slots\n",made,MP_JOB_SLOTS);
    g_started=TRUE;
    return TRUE;
}

// TRUE once at least one worker has actually reached its run loop -- see g_live.
static BOOL mp_live(){
    return mp_start()&&__atomic_load_n(&g_live,__ATOMIC_ACQUIRE)>0;
}

void mp_beginFrame(){
    g_burn_count=0;
    for(BurnNode* n=burnList;n!=NULL;n=n->next){
        if(g_burn_count>=MP_BURN_MAX){g_burn_count=-1;return;}
        g_burn[g_burn_count].x=n->x;
        g_burn[g_burn_count].y=n->y;
        g_burn[g_burn_count].z=n->z;
        g_burn_count++;
    }
}

// Built once per frame for the whole window rather than once per chunk, per the plan doc's §4.2
// item 4 -- and the common case is that the loop below never runs at all.
static BOOL mp_chunkBurning(const TerrainChunk* chunk){
    for(int i=0;i<g_burn_count;i++){
        const BurnPos* b=&g_burn[i];
        if(b->x>=chunk->pbounds[0]&&b->x<chunk->pbounds[0]+CHUNK_SIZE&&
           b->y>=chunk->pbounds[1]&&b->y<chunk->pbounds[1]+CHUNK_SIZE&&
           b->z>=chunk->pbounds[2]&&b->z<chunk->pbounds[2]+CHUNK_SIZE)
            return TRUE;
    }
    return FALSE;
}

BOOL mp_chunkBusy(const TerrainChunk* chunk){
    if(!chunk)return FALSE;
    // Relaxed is enough: only the main thread (this one) ever stores IDLE, so a chunk it sees as
    // busy cannot become idle behind its back. See TerrainChunk.h's note on that asymmetry.
    return __atomic_load_n(&chunk->meshJobState,__ATOMIC_RELAXED)!=MESH_JOB_IDLE;
}

BOOL mp_columnBusy(int cx,int cz){
    if(!chunkTablec)return FALSE;
    for(int cy=0;cy<CHUNKS_PER_COLUMN;cy++)
        if(mp_chunkBusy(chunkTablec[threeToOne(cx,cy,cz)]))return TRUE;
    return FALSE;
}

BOOL mp_dispatch(TerrainChunk* chunk,int idxn){
    if(!chunk||!mp_live()||g_burn_count<0||mp_chunkBusy(chunk)||mp_chunkBurning(chunk)){
        g_inlined++;
        return FALSE;
    }

    int slot=-1;
    pthread_mutex_lock(&g_lock);
    if(g_nfree>0)slot=g_free_slots[--g_nfree];
    pthread_mutex_unlock(&g_lock);
    if(slot<0){                     // kill switch 2: pool full -> today's exact code path
        g_inlined++;
        return FALSE;
    }

    MeshJob* j=&g_jobs[slot];
    j->chunk=chunk;
    j->idxn=idxn;
    j->sink_count=0;
    j->result=0;
    double t0=mp_now();
    memcpy(j->blocks,chunk->pblocks,sizeof(j->blocks));
    memcpy(j->colors,chunk->pcolors,sizeof(j->colors));
    g_snapshotMs+=mp_now()-t0;

    chunk->meshJobStale=FALSE;
    __atomic_store_n(&chunk->meshJobState,MESH_JOB_QUEUED,__ATOMIC_RELEASE);

    pthread_mutex_lock(&g_lock);
    g_queue[g_qtail]=slot;
    g_qtail=(g_qtail+1)%MP_JOB_SLOTS;
    g_qcount++;
    pthread_cond_signal(&g_work);
    pthread_mutex_unlock(&g_lock);

    g_dispatched++;
    return TRUE;
}

static void mp_publishOne(int slot,void (*redirty)(int),BOOL publish){
    MeshJob* j=&g_jobs[slot];
    TerrainChunk* chunk=j->chunk;

    // ACQUIRE, paired with the worker's RELEASE store. Everything the worker wrote into the
    // chunk's non-rt fields is visible from here on.
    (void)__atomic_load_n(&chunk->meshJobState,__ATOMIC_ACQUIRE);

    BOOL needs_retry=(j->result==-1);
    if(publish&&!needs_retry){
        tc_meshReplaySideEffects(j->sink,j->sink_count);
        chunk->prepareVBO();
        g_published++;
    }

    // Rule 2 of the plan doc's §4.3: an edit during the job produces a STALE mesh, not a torn one
    // (the worker read a snapshot). Publish it anyway and re-dirty -- a slightly-old mesh for one
    // frame is right, discarding it would leave the chunk with no geometry at all.
    BOOL stale=chunk->meshJobStale;
    if(stale)g_stale++;
    chunk->meshJobStale=FALSE;
    __atomic_store_n(&chunk->meshJobState,MESH_JOB_IDLE,__ATOMIC_RELEASE);

    pthread_mutex_lock(&g_lock);
    g_free_slots[g_nfree++]=slot;
    pthread_mutex_unlock(&g_lock);

    if(redirty&&(stale||needs_retry||!publish))redirty(j->idxn);
}

void mp_publishFinished(void (*redirty)(int)){
    for(;;){
        int slot=-1;
        pthread_mutex_lock(&g_lock);
        if(g_ndone>0)slot=g_done[--g_ndone];
        pthread_mutex_unlock(&g_lock);
        if(slot<0)return;
        mp_publishOne(slot,redirty,TRUE);
    }
}

void mp_drain(void (*redirty)(int),BOOL publish){
    if(!g_started)return;   // nothing was ever dispatched, so nothing can be in flight
    // Jobs are ~0.1 ms of CPU each and at most MP_JOB_SLOTS are outstanding, so this spins for
    // well under a frame in practice. It has to spin rather than block on a condvar because the
    // caller is the browser main thread, where blocking is at best discouraged; the guard just
    // keeps a lost worker from wedging the tab forever.
    for(long guard=0;guard<50000000L;guard++){
        for(;;){
            int slot=-1;
            pthread_mutex_lock(&g_lock);
            if(g_ndone>0)slot=g_done[--g_ndone];
            pthread_mutex_unlock(&g_lock);
            if(slot<0)break;
            mp_publishOne(slot,redirty,publish);
        }
        pthread_mutex_lock(&g_lock);
        int outstanding=MP_JOB_SLOTS-g_nfree;
        pthread_mutex_unlock(&g_lock);
        if(outstanding==0)return;
        sched_yield();
    }
    printg("MeshPool: mp_drain gave up waiting for in-flight mesh jobs\n");
}

#endif // EDEN_THREADED
