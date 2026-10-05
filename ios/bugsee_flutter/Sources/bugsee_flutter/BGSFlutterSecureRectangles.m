#import "BGSFlutterSecureRectangles.h"

#import <math.h>

/// Ints per secure widget in the Dart payload: id, x, y, width, height.
static const NSUInteger BGSFlutterIntsPerElement = 5;

static int32_t BGSFlutterClampToInt32(double value) {
    if (isnan(value)) {
        return 0;
    }
    if (value <= (double)INT32_MIN) {
        return INT32_MIN;
    }
    if (value >= (double)INT32_MAX) {
        return INT32_MAX;
    }
    return (int32_t)value;
}

NSData *BGSFlutterSecureRectanglesBuffer(const int32_t *elements, NSUInteger intCount, CGPoint origin) {
    if (elements == NULL && intCount > 0) {
        return nil;
    }
    const NSUInteger capacity = elements != NULL ? intCount / BGSFlutterIntsPerElement : 0;

    NSMutableData *data = [NSMutableData dataWithLength:(2 + 4 * capacity) * sizeof(int32_t)];
    int32_t *ints = data.mutableBytes;
    int32_t count = 0;

    for (NSUInteger i = 0; i < capacity; i++) {
        // elements[0] of each group is the element's id, unused here.
        const int32_t *element = elements + BGSFlutterIntsPerElement * i;
        const int32_t x = element[1];
        const int32_t y = element[2];
        const int32_t width = element[3];
        const int32_t height = element[4];
        if (width <= 0 || height <= 0) {
            continue;
        }
        // Moved first, rounded last: the origin can be fractional. Left and top round down, right
        // and bottom up, so a rectangle grows by under a point rather than leaving an edge of the
        // widget in the clear.
        const double left = origin.x + (double)x;
        const double top = origin.y + (double)y;
        const double right = origin.x + (double)x + (double)width;
        const double bottom = origin.y + (double)y + (double)height;

        int32_t *out = ints + 2 + 4 * count;
        out[0] = BGSFlutterClampToInt32(floor(left));
        out[1] = BGSFlutterClampToInt32(floor(top));
        out[2] = BGSFlutterClampToInt32(ceil(right));
        out[3] = BGSFlutterClampToInt32(ceil(bottom));
        count++;
    }

    // The set's version: BGSSecureRectanglesVersionUnknown, see the header.
    ints[0] = 0;
    ints[1] = count;
    data.length = (2 + 4 * (NSUInteger)count) * sizeof(int32_t);
    return [data copy];
}
