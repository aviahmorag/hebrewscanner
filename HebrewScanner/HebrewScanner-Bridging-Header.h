//
//  HebrewScanner-Bridging-Header.h
//  HebrewScanner
//
//  Created by Aviah Morag in 2026.
//

#ifndef HebrewScanner_Bridging_Header_h
#define HebrewScanner_Bridging_Header_h

// Opaque types
typedef struct TessBaseAPI TessBaseAPI;
typedef struct Pix Pix;

// Page segmentation modes (we only need PSM_SINGLE_BLOCK)
typedef enum {
    PSM_OSD_ONLY       = 0,
    PSM_AUTO_OSD       = 1,
    PSM_AUTO_ONLY      = 2,
    PSM_AUTO           = 3,
    PSM_SINGLE_COLUMN  = 4,
    PSM_SINGLE_BLOCK_VERT_TEXT = 5,
    PSM_SINGLE_BLOCK   = 6,
    PSM_SINGLE_LINE    = 7,
    PSM_SINGLE_WORD    = 8,
    PSM_CIRCLE_WORD    = 9,
    PSM_SINGLE_CHAR    = 10,
    PSM_SPARSE_TEXT    = 11,
    PSM_SPARSE_TEXT_OSD = 12,
    PSM_RAW_LINE       = 13,
    PSM_COUNT          = 14
} TessPageSegMode;

// Tesseract API
TessBaseAPI *TessBaseAPICreate(void);
int          TessBaseAPIInit3(TessBaseAPI *handle, const char *datapath, const char *language);
void         TessBaseAPISetPageSegMode(TessBaseAPI *handle, TessPageSegMode mode);
void         TessBaseAPISetImage2(TessBaseAPI *handle, struct Pix *pix);
int          TessBaseAPIRecognize(TessBaseAPI *handle, void *monitor);
char        *TessBaseAPIGetTsvText(TessBaseAPI *handle, int page_number);
char        *TessBaseAPIGetUTF8Text(TessBaseAPI *handle);
void         TessBaseAPIEnd(TessBaseAPI *handle);
void         TessBaseAPIDelete(TessBaseAPI *handle);
void         TessDeleteText(const char *text);

// Leptonica API
Pix         *pixRead(const char *filename);
void         pixDestroy(Pix **ppix);

#endif
