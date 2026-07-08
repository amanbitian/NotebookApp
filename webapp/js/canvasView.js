// Shared by CanvasView (live rendering) and pdfExport.js (flattening at export time) —
// same reuse rationale as ExportJob.renderPDFFile being shared with the backup path
// in the Swift app: one renderer, not two copies to keep in sync.
export function drawStrokeOnContext(ctx, stroke) {
  const points = stroke.points;
  if (points.length === 0) return;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.strokeStyle = stroke.color;
  ctx.lineWidth = stroke.width;

  if (points.length === 1) {
    ctx.beginPath();
    ctx.arc(points[0].x, points[0].y, stroke.width / 2, 0, Math.PI * 2);
    ctx.fillStyle = stroke.color;
    ctx.fill();
    return;
  }

  ctx.beginPath();
  ctx.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length - 1; i++) {
    const midX = (points[i].x + points[i + 1].x) / 2;
    const midY = (points[i].y + points[i + 1].y) / 2;
    ctx.quadraticCurveTo(points[i].x, points[i].y, midX, midY);
  }
  const last = points[points.length - 1];
  ctx.lineTo(last.x, last.y);
  ctx.stroke();
}

// The web analogue of CanvasView.swift + PKCanvasView: renders vector strokes and
// forwards pointer input. Deliberately dumb about persistence/undo — same separation
// as P1 ("the render path and the persistence path are fully decoupled"). The
// controller that owns this instance decides what a completed stroke means for
// storage and undo.
export class CanvasView {
  constructor(canvasEl, { onStrokeCompleted, onStrokesErased, onTextAnnotationRequested, onAnnotationsErased, onAnnotationMoved, onAnnotationResized } = {}) {
    this.canvas = canvasEl;
    this.ctx = canvasEl.getContext("2d");
    this.onStrokeCompleted = onStrokeCompleted || (() => {});
    this.onStrokesErased = onStrokesErased || (() => {});
    this.onTextAnnotationRequested = onTextAnnotationRequested || (() => {});
    this.onAnnotationsErased = onAnnotationsErased || (() => {});
    this.onAnnotationMoved = onAnnotationMoved || (() => {});
    this.onAnnotationResized = onAnnotationResized || (() => {});

    this.strokes = [];
    this.annotations = [];
    this.backgroundImage = null;
    this.tool = "pen";
    this.color = "#1a1a1a";
    this.width = 3;

    this._activeStroke = null;
    this._eraseHits = new Set();
    this._eraseAnnotationHits = new Set();
    this._imageBitmapCache = new Map(); // annotation id -> ImageBitmap
    this._drag = null; // { annotationId, originX, originY, pointerStartX, pointerStartY, moved }
    this._resize = null; // { annotationId, originWidth, originHeight, pointerStartX, pointerStartY, resized }
    this._resizeHandleSize = 14;
    this._pageWidthCss = 850;
    this._pageHeightCss = 1100;

    canvasEl.addEventListener("pointerdown", this._onPointerDown.bind(this));
    canvasEl.addEventListener("pointermove", this._onPointerMove.bind(this));
    canvasEl.addEventListener("pointerup", this._onPointerUp.bind(this));
    canvasEl.addEventListener("pointercancel", this._onPointerUp.bind(this));
  }

  setTool(tool) {
    this.tool = tool;
  }

  setColor(color) {
    this.color = color;
  }

  setWidth(width) {
    this.width = width;
  }

  setPageSize(widthCss, heightCss) {
    this._pageWidthCss = widthCss;
    this._pageHeightCss = heightCss;
    const dpr = window.devicePixelRatio || 1;
    this.canvas.width = widthCss * dpr;
    this.canvas.height = heightCss * dpr;
    this.canvas.style.width = `${widthCss}px`;
    this.canvas.style.height = `${heightCss}px`;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.render();
  }

  setStrokes(strokes) {
    this.strokes = strokes;
    this.render();
  }

  // Only called on page open/switch (never mid-edit — in-place changes go through
  // addAnnotationInternal/removeAnnotationInternal/moveAnnotationInternal instead), so
  // it's safe to drop decoded bitmaps for whatever page was showing before. Without
  // this, the cache grew for the life of the tab across every page ever opened.
  setAnnotations(annotations) {
    this._imageBitmapCache.clear();
    this.annotations = annotations;
    this._decodeMissingImageAnnotations();
    this.render();
  }

  // Blobs need async decoding to draw; text can render immediately. A page reopened
  // after a browser restart, or an image just inserted, both flow through here.
  _decodeMissingImageAnnotations() {
    for (const annotation of this.annotations) {
      if (annotation.kind !== "image" || this._imageBitmapCache.has(annotation.id)) continue;
      if (!annotation.imageBlob) continue;
      createImageBitmap(annotation.imageBlob).then((bitmap) => {
        this._imageBitmapCache.set(annotation.id, bitmap);
        this.render();
      });
    }
  }

  setBackgroundImage(image) {
    this.backgroundImage = image;
    this.render();
  }

  // Called by the undo stack when replaying a command — idempotent by id so the
  // initial `perform()` (which calls redo() on a stroke already pushed live during
  // drawing) doesn't duplicate it.
  addStrokeInternal(stroke) {
    if (!this.strokes.some((s) => s.id === stroke.id)) {
      this.strokes.push(stroke);
    }
    this.render();
  }

  removeStrokesInternal(strokeIds) {
    const idSet = new Set(strokeIds);
    this.strokes = this.strokes.filter((s) => !idSet.has(s.id));
    this.render();
  }

  addAnnotationInternal(annotation) {
    if (!this.annotations.some((a) => a.id === annotation.id)) {
      this.annotations.push(annotation);
    }
    this._decodeMissingImageAnnotations();
    this.render();
  }

  removeAnnotationInternal(annotationId) {
    this.annotations = this.annotations.filter((a) => a.id !== annotationId);
    this.render();
  }

  // Called by the undo stack when replaying a move — live dragging already updates
  // x/y directly on the annotation object, so this only matters for undo/redo.
  moveAnnotationInternal(annotationId, x, y) {
    const annotation = this.annotations.find((a) => a.id === annotationId);
    if (annotation) {
      annotation.x = x;
      annotation.y = y;
      this.render();
    }
  }

  // Same idea as moveAnnotationInternal, for resize.
  resizeAnnotationInternal(annotationId, width, height) {
    const annotation = this.annotations.find((a) => a.id === annotationId);
    if (annotation) {
      annotation.width = width;
      annotation.height = height;
      this.render();
    }
  }

  render() {
    const ctx = this.ctx;
    ctx.save();
    ctx.clearRect(0, 0, this._pageWidthCss, this._pageHeightCss);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, this._pageWidthCss, this._pageHeightCss);
    if (this.backgroundImage) {
      ctx.drawImage(this.backgroundImage, 0, 0, this._pageWidthCss, this._pageHeightCss);
    }
    for (const stroke of this.strokes) {
      this._drawStroke(stroke);
    }
    for (const annotation of this.annotations) {
      this._drawAnnotation(annotation);
    }
    if (this.tool === "move") {
      for (const annotation of this.annotations) {
        if (annotation.kind === "image") this._drawResizeHandle(annotation);
      }
    }
    ctx.restore();
  }

  _drawAnnotation(annotation) {
    const ctx = this.ctx;
    if (annotation.kind === "image") {
      const bitmap = this._imageBitmapCache.get(annotation.id);
      if (bitmap) {
        ctx.drawImage(bitmap, annotation.x, annotation.y, annotation.width, annotation.height);
      }
      return;
    }
    ctx.fillStyle = "#1a1a1a";
    ctx.font = "16px sans-serif";
    ctx.textBaseline = "top";
    ctx.fillText(annotation.text, annotation.x, annotation.y);
  }

  // Visual affordance for the resize hit-zone in _resizeHandleBounds — otherwise
  // there's no way to discover that dragging the corner resizes rather than moves.
  _drawResizeHandle(annotation) {
    const ctx = this.ctx;
    const b = this._resizeHandleBounds(annotation);
    ctx.fillStyle = "rgba(26, 115, 232, 0.9)";
    ctx.fillRect(b.x, b.y, b.width, b.height);
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 1;
    ctx.strokeRect(b.x, b.y, b.width, b.height);
  }

  _resizeHandleBounds(annotation) {
    const size = this._resizeHandleSize;
    return {
      x: annotation.x + annotation.width - size / 2,
      y: annotation.y + annotation.height - size / 2,
      width: size,
      height: size,
    };
  }

  // Bounding box used for both the "move" tool's hit-testing and the eraser. Text
  // annotations don't carry a stored width/height (drawn at natural size), so this
  // estimates one from the rendered text metrics.
  _annotationBounds(annotation) {
    if (annotation.kind === "image") {
      return { x: annotation.x, y: annotation.y, width: annotation.width, height: annotation.height };
    }
    this.ctx.font = "16px sans-serif";
    const width = this.ctx.measureText(annotation.text).width;
    return { x: annotation.x, y: annotation.y, width, height: 20 };
  }

  _hitTestAnnotation(point) {
    for (let i = this.annotations.length - 1; i >= 0; i--) {
      const annotation = this.annotations[i];
      const b = this._annotationBounds(annotation);
      if (point.x >= b.x && point.x <= b.x + b.width && point.y >= b.y && point.y <= b.y + b.height) {
        return annotation;
      }
    }
    return null;
  }

  // Only images are resizable (text annotations have no stored width/height — same
  // scope as the Swift app's edit sheet, which is image-only).
  _hitTestResizeHandle(point) {
    for (let i = this.annotations.length - 1; i >= 0; i--) {
      const annotation = this.annotations[i];
      if (annotation.kind !== "image") continue;
      const b = this._resizeHandleBounds(annotation);
      if (point.x >= b.x && point.x <= b.x + b.width && point.y >= b.y && point.y <= b.y + b.height) {
        return annotation;
      }
    }
    return null;
  }

  _drawStroke(stroke) {
    drawStrokeOnContext(this.ctx, stroke);
  }

  _localPoint(event) {
    const rect = this.canvas.getBoundingClientRect();
    return {
      x: event.clientX - rect.left,
      y: event.clientY - rect.top,
      pressure: event.pressure && event.pressure > 0 ? event.pressure : 0.5,
    };
  }

  _onPointerDown(event) {
    this.canvas.setPointerCapture(event.pointerId);
    const point = this._localPoint(event);

    if (this.tool === "eraser") {
      this._eraseHits.clear();
      this._eraseAnnotationHits.clear();
      this._eraseAt(point);
      return;
    }

    if (this.tool === "text") {
      this.onTextAnnotationRequested(point);
      return;
    }

    if (this.tool === "move") {
      const resizeHit = this._hitTestResizeHandle(point);
      if (resizeHit) {
        this._resize = {
          annotationId: resizeHit.id,
          originWidth: resizeHit.width,
          originHeight: resizeHit.height,
          pointerStartX: point.x,
          pointerStartY: point.y,
          resized: false,
        };
        return;
      }

      const hit = this._hitTestAnnotation(point);
      if (hit) {
        this._drag = {
          annotationId: hit.id,
          originX: hit.x,
          originY: hit.y,
          pointerStartX: point.x,
          pointerStartY: point.y,
          moved: false,
        };
      }
      return;
    }

    this._activeStroke = {
      id: crypto.randomUUID(),
      tool: "pen",
      color: this.color,
      width: this.width,
      points: [point],
    };
    this.strokes.push(this._activeStroke);
    this.render();
  }

  _onPointerMove(event) {
    if (event.buttons === 0) return;
    const point = this._localPoint(event);

    if (this.tool === "eraser") {
      this._eraseAt(point);
      return;
    }

    if (this.tool === "move") {
      if (this._resize) {
        const annotation = this.annotations.find((a) => a.id === this._resize.annotationId);
        if (!annotation) return;
        const minSize = 20;
        const aspect = this._resize.originHeight / Math.max(this._resize.originWidth, 1);
        const deltaX = point.x - this._resize.pointerStartX;
        annotation.width = Math.max(minSize, this._resize.originWidth + deltaX);
        annotation.height = annotation.width * aspect;
        this._resize.resized = true;
        this.render();
        return;
      }

      if (!this._drag) return;
      const annotation = this.annotations.find((a) => a.id === this._drag.annotationId);
      if (!annotation) return;
      annotation.x = this._drag.originX + (point.x - this._drag.pointerStartX);
      annotation.y = this._drag.originY + (point.y - this._drag.pointerStartY);
      this._drag.moved = true;
      this.render();
      return;
    }

    if (!this._activeStroke) return;
    this._activeStroke.points.push(point);
    this.render();
  }

  _onPointerUp() {
    if (this.tool === "eraser") {
      const removedStrokes = this.strokes.filter((s) => this._eraseHits.has(s.id));
      const removedAnnotations = this.annotations.filter((a) => this._eraseAnnotationHits.has(a.id));
      if (removedStrokes.length > 0) {
        this.strokes = this.strokes.filter((s) => !this._eraseHits.has(s.id));
      }
      if (removedAnnotations.length > 0) {
        this.annotations = this.annotations.filter((a) => !this._eraseAnnotationHits.has(a.id));
      }
      if (removedStrokes.length > 0 || removedAnnotations.length > 0) {
        this.render();
        if (removedStrokes.length > 0) this.onStrokesErased(removedStrokes);
        if (removedAnnotations.length > 0) this.onAnnotationsErased(removedAnnotations);
      }
      this._eraseHits.clear();
      this._eraseAnnotationHits.clear();
      return;
    }

    if (this.tool === "move") {
      if (this._resize && this._resize.resized) {
        const annotation = this.annotations.find((a) => a.id === this._resize.annotationId);
        if (annotation) {
          this.onAnnotationResized({
            annotation,
            fromWidth: this._resize.originWidth,
            fromHeight: this._resize.originHeight,
            toWidth: annotation.width,
            toHeight: annotation.height,
          });
        }
      }
      this._resize = null;

      if (this._drag && this._drag.moved) {
        const annotation = this.annotations.find((a) => a.id === this._drag.annotationId);
        if (annotation) {
          this.onAnnotationMoved({
            annotation,
            fromX: this._drag.originX,
            fromY: this._drag.originY,
            toX: annotation.x,
            toY: annotation.y,
          });
        }
      }
      this._drag = null;
      return;
    }

    if (this._activeStroke && this._activeStroke.points.length > 0) {
      const finished = this._activeStroke;
      this._activeStroke = null;
      this.onStrokeCompleted(finished);
    }
  }

  // Whole-stroke eraser: removes any stroke whose path comes within `radius` of the
  // eraser point. Simpler than PencilKit's segment-splitting eraser (§7.3's
  // "partial-eraser wrinkle") — that nuance mattered for merge conflicts, which don't
  // apply to a single-browser local store, so it's not reproduced here. Also erases
  // any annotation (image/text) whose bounding box contains the point.
  _eraseAt(point, radius = 10) {
    for (const stroke of this.strokes) {
      if (this._eraseHits.has(stroke.id)) continue;
      for (const p of stroke.points) {
        const dx = p.x - point.x;
        const dy = p.y - point.y;
        if (dx * dx + dy * dy <= radius * radius) {
          this._eraseHits.add(stroke.id);
          break;
        }
      }
    }
    const hitAnnotation = this._hitTestAnnotation(point);
    if (hitAnnotation) this._eraseAnnotationHits.add(hitAnnotation.id);
  }
}
