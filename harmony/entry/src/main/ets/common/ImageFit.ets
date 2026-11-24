/** Fitted display size of an image inside the available viewport. */
export interface FittedSize {
  width: number;
  height: number;
}

/** On-screen rect of the tapped image in the article WebView (vp). Used as the
 *  starting point of the open animation in the full-screen viewer. */
export interface ImageRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * Fit an intrinsic image size (already in vp) into the available area while
 * preserving aspect ratio. Small images are never upscaled, matching Android's
 * ContentScale.Inside. The caller sizes the Image component to this result and
 * lets the Stack centre the component, instead of relying on objectFit's
 * in-box alignment (which is not consistently centred on all ArkUI builds).
 */
export function fitImageSize(
  imageWidth: number, imageHeight: number, areaWidth: number, areaHeight: number
): FittedSize {
  if (imageWidth <= 0 || imageHeight <= 0 || areaWidth <= 0 || areaHeight <= 0) {
    return { width: 0, height: 0 };
  }
  const scale: number = Math.min(1, areaWidth / imageWidth, areaHeight / imageHeight);
  return { width: imageWidth * scale, height: imageHeight * scale };
}
