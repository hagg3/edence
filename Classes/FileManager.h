//
//  FileManager.h
//  prototype
//
//  Created by Ari Ronen on 10/25/10.
//  Copyright 2010 __MyCompanyName__. All rights reserved.
//
#ifndef Eden_FileManager_h
#define Eden_FileManager_h


#import "Terrain.h"



#define FILE_VERSION 4
// The first header version that means 256 blocks tall (16 chunk-bands per column record).
// version 6 exists in the wild too and is treated as 256z; what distinguishes it from 5 is
// unknown, so a >=5 file keeps its OWN version on save -- see docs/eden-file-format.md.
#define FILE_VERSION_256Z 5
#define FILE_VERSION_256Z_MAX 6
// Runtime, because CHUNKS_PER_COLUMN is (Constants.h): 32768 at 64z, 131072 at 256z.
#define SIZEOF_COLUMN ((unsigned long long)g_column_bytes)


typedef struct{
	int level_seed;
	Vector pos;
	Vector home;
	float yaw;
	unsigned long long directory_offset;
	char name[50];
    
    //below here is post 1.1.1 stuff
    int version;
    char hash[36];
    unsigned char skycolors[16];
    int goldencubes;
	char reserved[100-sizeof(int)-36-16-sizeof(int)];	 //subtract new stuff from reserve bytes,
    //192 bytes(including padding is the correct size, be careful modifying this to not corrupt old maps
}WorldFileHeader;
typedef struct{
	int x, z;
	unsigned long long chunk_offset;
}ColumnIndex;
typedef struct{
	int n_vertices;

}ChunkHeader;

// 256z Stage 3 item 5: the in-app "Convert to 64z" action (Settings -> Storage tab). Same report
// shape as web/tools/eden-convert.js's --to-64 direction, whose algorithm this is a from-scratch
// C++ port of (see FileManager::convertWorldTo64's own header comment for what's shared and what
// isn't). `ok`==FALSE means nothing was written; `error` explains why.
typedef struct{
    BOOL ok;
    char error[160];
    int columns;
    int blocksDiscarded;
    int columnsAffected;
    int doorsOrphaned;
    int creaturesDropped;
    int creaturesRelocated;
    int creaturesOverflow;
    BOOL posClamped;
    BOOL homeClamped;
}ConvertTo64Report;

class FileManager {
public:
    int chunkOffsetX;
    int chunkOffsetZ;
    
    NSString* documents;
    BOOL convertingWorld;
    BOOL genflat;
    FileManager();
    BOOL worldExists(std::string name,BOOL appendArchive);
    void saveColumn(int cx,int cz);
    void saveGenColumn(int cx,int cz,int origin);
    void readColumn(int cx,int cz,NSFileHandle* nsfh);
    void saveWorld();
    void saveWorld(Vector warp);
    void loadGenFromDisk();
    void writeGenToDisk();
    void fwriteDirectory();
    void readDirectory();
    void clearDirectory();
    void compressLastPlayed();
    void convertFile(NSString* file_name);
    NSString* getName(NSString* file_name);
    void setName(std::string fn,std::string dn);
    void setImageHash(NSString* hash);
    void loadWorld(NSString* name,BOOL fromArchive);
    BOOL deleteWorld(NSString* name);
    // Reads ONLY the header of an existing save and answers 64 or 256, so World::loadWorld can call
    // eden_set_world_height() before Terrain::allocateMemory() sizes the per-world arrays. A world
    // that does not exist yet (or any file we can't read a header from) answers 64: new worlds are
    // 64z, which is the decision recorded in the 256z plan.
    int probeWorldHeight(NSString* name,BOOL fromArchive);
    // 256z Stage 3 item 5: convert an existing 256z ("New Dawn") save to 64z in place (space
    // reclaim). Destructive -- see the function body for exactly what it discards -- so it writes
    // to a scratch file and only replaces the original on full success, same temp+rename pattern
    // saveWorld() uses. Refuses if `name` is the world currently open in this session.
    ConvertTo64Report convertWorldTo64(NSString* name);

private:
    int oldOffsetX;
    int oldOffsetZ;
    void LoadCreatures();
    void saveCreatures();
    // Per-column record span, in bytes, for the columns whose span is SHORTER than a full record.
    // The New Dawn specimen has exactly one such column (107,072 B where 131,072 was expected), and
    // reading it at full stride would pull in 24,000 bytes of its neighbour. Keyed by twoToOne(x,z),
    // value is the byte span; a column absent from this map has a full-size record.
    void* shortSpans;   // map_t (hashmap.h); declared void* so this header stays include-order-free
    void deriveColumnSpans();
    void clearColumnSpans();
    // B5: if the last save of this world was interrupted mid-write, put the file back the way the
    // last COMPLETE save left it, using the small journal saveWorld() writes before it starts
    // rewriting a large file in place. A no-op (one stat) when there is no journal, which is every
    // world below g_save_inplace_threshold and every world whose last save finished normally.
    void recoverInterruptedSave(NSString* file_name);
};
std::string fullPathForFilename(const char* fn);
#endif