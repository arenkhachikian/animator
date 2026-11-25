//// Animator -- an application for program-generated drawings.

import builtins
import data
import drawing
import editor
import errors
import examples
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import lustre
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import parser
import render
import shape.{type Path}

/// Your app's public address, once you've deployed it in Problem 13, such as
/// "https://your-username.github.io/animator/".
pub const public_url = ""

/// Set to True if you would like your app's URL included in the course gallery.
pub const include_app_in_gallery = False

/// A link to your video from Problem 14, which anyone with the link can watch.
pub const video_url = ""

/// Set to True if you would like your video included in the course gallery.
pub const include_video_in_gallery = False

const default_code =
  "fn draw(shape_slider: Int) -> List(Path) {\n  [Path(Line(Point(0, 0), Point(100, 100)), 0, 10, 2)]\n}\n"

// localStorage keeps the whole library, including which drawing is open:
// {"active": name, "drawings": [{"name": name, "source": source}, ...]}.
const storage_key = "animator-drawings"

const stroke_color = "#e8d5a3"

const min_shape = 0

const max_shape = 100

const min_speed = -1.0

const max_speed = 4.0

// ── Model ──────────────────────────────────────────────────────────────────────

pub type Model {
  Model(
    // The code in the editor.
    source: String,
    // Whether the code editor is shown.
    code_open: Bool,
    // A parse or evaluation error, or "" when the current source draws.
    output: String,
    // The Int passed to draw. Range inputs report it as text.
    shape_slider: Int,
    // Playback rate passed to the canvas. 1.0 is normal speed. 0 pauses.
    speed: Float,
    // Speed restored by Resume after Pause. Stays non-zero.
    resume_speed: Float,
    // Canvas clock, in tenths of a second, shown on the timeline.
    timeline: Float,
    // When the last path of the current drawing finishes, in tenths.
    duration: Float,
    // True while the timeline is being dragged, so playback doesn't fight it.
    scrubbing: Bool,
    // Every saved drawing, name then source. Names are unique.
    drawings: List(#(String, String)),
    // Name of the drawing open in the editor.
    active: String,
  )
}

pub type Msg {
  SetCode(String)
  ToggleCode
  Boot
  SetShapeText(String)
  SetSpeedText(String)
  SelectDrawing(String)
  PromptNewDrawing
  CreateDrawing(String)
  // Timeline extension. Clock is the canvas clock, in tenths of a second.
  Clock(Float)
  SetTimeline(String)
  ReleaseTimeline
  TogglePause
}

// ── Init ───────────────────────────────────────────────────────────────────────

pub fn init(_flags: Nil) -> #(Model, Effect(Msg)) {
  let #(drawings, active) = load_library()
  let source = active_source(drawings, active)
  #(
    Model(
      source: source,
      code_open: True,
      output: "",
      shape_slider: 0,
      speed: 1.0,
      resume_speed: 1.0,
      timeline: 0.0,
      duration: 0.0,
      scrubbing: False,
      drawings: drawings,
      active: active,
    ),
    effect.from(fn(dispatch) { dispatch(Boot) }),
  )
}

// Parse and evaluate a draw function at the given shape-slider value, returning
// the rendered paths on success, or a human-readable message on failure.
fn run_source(shape_slider: Int, source: String) -> Result(List(Path), String) {
  case parser.parse_program(source, builtins.global_frame()) {
    Error(msg) -> Error(msg)
    Ok(program) ->
      drawing.try_draw(shape_slider, program)
      // Convert Error(EvalError) to Error(String) with a useful error message.
      |> result.map_error(errors.error_message)
  }
}

// ── Drawings library ───────────────────────────────────────────────────────────

fn fallback_library() -> #(List(#(String, String)), String) {
  case examples.all {
    [#(name, _), ..] -> #(examples.all, name)
    [] -> #([#("drawing", default_code)], "drawing")
  }
}

fn load_library() -> #(List(#(String, String)), String) {
  case data.storage_get(storage_key) {
    Error(_) -> fallback_library()
    Ok(raw) ->
      case json.parse(raw, library_decoder()) {
        Ok(#(active, drawings)) -> usable_library(active, drawings)
        Error(_) -> fallback_library()
      }
  }
}

fn usable_library(
  active: String,
  drawings: List(#(String, String)),
) -> #(List(#(String, String)), String) {
  case drawings {
    [] -> fallback_library()
    [#(first, _), ..] ->
      case list.key_find(drawings, active) {
        Ok(_) -> #(drawings, active)
        Error(_) -> #(drawings, first)
      }
  }
}

fn active_source(drawings: List(#(String, String)), active: String) -> String {
  case list.key_find(drawings, active) {
    Ok(source) -> source
    Error(_) -> default_code
  }
}

fn update_drawing(
  drawings: List(#(String, String)),
  active: String,
  source: String,
) -> List(#(String, String)) {
  list.map(drawings, fn(drawing) {
    let #(name, previous) = drawing
    case name == active {
      True -> #(name, source)
      False -> #(name, previous)
    }
  })
}

fn unique_name(name: String, drawings: List(#(String, String))) -> String {
  case list.key_find(drawings, name) {
    Error(_) -> name
    Ok(_) -> unique_name_from(name, drawings, 2)
  }
}

fn unique_name_from(
  name: String,
  drawings: List(#(String, String)),
  n: Int,
) -> String {
  let candidate = name <> " " <> int.to_string(n)
  case list.key_find(drawings, candidate) {
    Error(_) -> candidate
    Ok(_) -> unique_name_from(name, drawings, n + 1)
  }
}

fn library_decoder() -> decode.Decoder(#(String, List(#(String, String)))) {
  use active <- decode.field("active", decode.string)
  use drawings <- decode.field("drawings", decode.list(drawing_decoder()))
  decode.success(#(active, drawings))
}

fn drawing_decoder() -> decode.Decoder(#(String, String)) {
  use name <- decode.field("name", decode.string)
  use source <- decode.field("source", decode.string)
  decode.success(#(name, source))
}

fn encode_library(active: String, drawings: List(#(String, String))) -> String {
  json.object([
    #("active", json.string(active)),
    #(
      "drawings",
      json.array(drawings, fn(drawing) {
        let #(name, source) = drawing
        json.object([
          #("name", json.string(name)),
          #("source", json.string(source)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn persist(drawings: List(#(String, String)), active: String) -> Effect(Msg) {
  let encoded = encode_library(active, drawings)
  effect.from(fn(_dispatch) { data.storage_set(storage_key, encoded) })
}

// ── Rendering ──────────────────────────────────────────────────────────────────

fn show_drawing(paths: List(Path), reset: Bool) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    case reset {
      True -> render.reset_clock()
      False -> Nil
    }
    list.map(paths, fn(path) { render.render_path(path, stroke_color) })
    |> render.set_drawing
  })
}

fn apply_speed(rate: Float) -> Effect(Msg) {
  effect.from(fn(_dispatch) { render.set_speed(rate) })
}

fn seek(time: Float) -> Effect(Msg) {
  effect.from(fn(_dispatch) { render.set_clock(time) })
}

// The canvas clock keeps moving after Boot. Later messages only read it.
fn follow_clock() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    render.watch_clock(fn(time) { dispatch(Clock(time)) })
  })
}

// How long the drawing takes to finish, in tenths of a second. An instant path
// finishes when it starts.
fn drawing_span(paths: List(Path)) -> Float {
  list.fold(paths, 0.0, fn(span, path) {
    let finish = case path.end >. path.start {
      True -> path.end
      False -> path.start
    }
    case finish >. span {
      True -> finish
      False -> span
    }
  })
}

// Re-evaluate source at the current shape slider. Save the text onto the active
// drawing when save is True, including when it does not parse or evaluate.
// reset restarts the animation; the shape slider leaves the clock where it is
// so a finished drawing stays complete while the shape changes.
fn present(
  model: Model,
  source: String,
  reset: Bool,
  save: Bool,
) -> #(Model, Effect(Msg)) {
  let drawings = update_drawing(model.drawings, model.active, source)
  let model = Model(..model, source: source, drawings: drawings)
  let persisted = case save {
    True -> persist(drawings, model.active)
    False -> effect.none()
  }
  case run_source(model.shape_slider, source) {
    Ok(paths) -> {
      let duration = drawing_span(paths)
      let timeline = case reset {
        True -> 0.0
        False -> float.min(model.timeline, duration)
      }
      #(
        Model(
          ..model,
          output: "",
          duration: duration,
          timeline: timeline,
          scrubbing: False,
        ),
        effect.batch([persisted, show_drawing(paths, reset)]),
      )
    }
    Error(message) -> {
      let cleared = case reset {
        True -> show_drawing([], True)
        False -> effect.none()
      }
      let model = case reset {
        True ->
          Model(
            ..model,
            output: message,
            timeline: 0.0,
            duration: 0.0,
            scrubbing: False,
          )
        False -> Model(..model, output: message)
      }
      #(model, effect.batch([persisted, cleared]))
    }
  }
}

fn open_editor(source: String, fx: Effect(Msg)) -> Effect(Msg) {
  effect.batch([editor.mount(source, SetCode), fx])
}

// ── Update ─────────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ToggleCode -> #(Model(..model, code_open: !model.code_open), effect.none())

    Boot -> {
      let #(drawings, active) = load_library()
      let source = active_source(drawings, active)
      let model =
        Model(
          ..model,
          drawings: drawings,
          active: active,
          source: source,
          output: "",
        )
      let #(model, fx) = present(model, source, True, False)
      #(
        model,
        effect.batch([
          open_editor(source, fx),
          apply_speed(model.speed),
          follow_clock(),
        ]),
      )
    }

    // After each keystroke in the editor, evaluate user code and report errors.
    SetCode(text) -> present(model, text, False, True)

    SetShapeText(raw) ->
      case int.parse(raw) {
        Error(_) -> #(model, effect.none())
        Ok(value) -> {
          let value = int.clamp(value, min: min_shape, max: max_shape)
          case value == model.shape_slider {
            True -> #(model, effect.none())
            False -> {
              let model = Model(..model, shape_slider: value)
              present(model, model.source, False, False)
            }
          }
        }
      }

    SetSpeedText(raw) ->
      case parse_speed(raw) {
        Error(_) -> #(model, effect.none())
        Ok(value) ->
          case value == model.speed {
            True -> #(model, effect.none())
            False -> {
              let resume = case value == 0.0 {
                True -> model.resume_speed
                False -> value
              }
              #(
                Model(..model, speed: value, resume_speed: resume),
                apply_speed(value),
              )
            }
          }
      }

    Clock(time) ->
      case model.scrubbing {
        True -> #(model, effect.none())
        False -> #(Model(..model, timeline: time), effect.none())
      }

    // Hold the clock still while the thumb moves, then let ReleaseTimeline
    // continue at the speed slider's rate.
    SetTimeline(raw) ->
      case parse_decimal(raw) {
        Error(_) -> #(model, effect.none())
        Ok(time) -> {
          let time = float.clamp(time, min: 0.0, max: model.duration)
          #(
            Model(..model, timeline: time, scrubbing: True),
            effect.batch([apply_speed(0.0), seek(time)]),
          )
        }
      }

    ReleaseTimeline -> #(
      Model(..model, scrubbing: False),
      apply_speed(model.speed),
    )

    TogglePause ->
      case model.speed == 0.0 {
        True -> {
          let rate = case model.resume_speed == 0.0 {
            True -> 1.0
            False -> model.resume_speed
          }
          #(Model(..model, speed: rate), apply_speed(rate))
        }
        False -> #(
          Model(..model, speed: 0.0, resume_speed: model.speed),
          apply_speed(0.0),
        )
      }

    SelectDrawing(name) ->
      case name == model.active {
        True -> #(model, effect.none())
        False ->
          case list.key_find(model.drawings, name) {
            Error(_) -> #(model, effect.none())
            Ok(source) -> {
              let model = Model(..model, active: name)
              let #(model, fx) = present(model, source, True, True)
              #(model, open_editor(source, fx))
            }
          }
      }

    PromptNewDrawing -> #(
      model,
      effect.from(fn(dispatch) {
        dispatch(CreateDrawing(data.prompt_drawing_name()))
      }),
    )

    CreateDrawing(raw) -> {
      let name = string.trim(raw)
      case name {
        "" -> #(model, effect.none())
        name -> {
          let name = unique_name(name, model.drawings)
          let drawings = list.append(model.drawings, [#(name, default_code)])
          let model = Model(..model, drawings: drawings, active: name)
          let #(model, fx) = present(model, default_code, True, True)
          #(model, open_editor(default_code, fx))
        }
      }
    }
  }
}

fn round_tenth(value: Float) -> Float {
  int.to_float(float.round(value *. 10.0)) /. 10.0
}

// Range inputs report whole numbers as "0" or "4". gleam's float parser only
// accepts a decimal point, so those positions would otherwise be ignored.
fn parse_decimal(raw: String) -> Result(Float, Nil) {
  let normalized = case string.contains(raw, ".") {
    True -> raw
    False -> raw <> ".0"
  }
  case float.parse(normalized) {
    Ok(value) -> Ok(round_tenth(value))
    Error(_) -> Error(Nil)
  }
}

fn parse_speed(raw: String) -> Result(Float, Nil) {
  case parse_decimal(raw) {
    Ok(value) ->
      Ok(float.clamp(value, min: min_speed, max: max_speed))
    Error(_) -> Error(Nil)
  }
}

// ── View ──────────────────────────────────────────────────────────────────
//
// Two side-by-side panes: the code editor on the left and its rendered output on
// the right. The code column can be hidden to expand the right pane.

pub fn view(model: Model) -> Element(Msg) {
  let app_class = case model.code_open {
    True -> "app"
    False -> "app code-hidden"
  }
  // The code column still exists even when hidden (CSS collapses it) so the
  // mounted CodeMirror editor keeps its state across show/hide.
  html.div([attr.class(app_class)], [
    html.div([attr.class("code-col")], [
      editor.view_panel(ToggleCode),
    ]),
    view_anim(model),
  ])
}

fn view_anim(model: Model) -> Element(Msg) {
  html.div([attr.class("canvas-area")], [
    view_reveal_code(model),
    html.div([attr.class("stage")], [
      html.canvas([attr.id("animation-canvas"), attr.class("canvas")]),
      view_error(model),
    ]),
    view_controls(model),
  ])
}

fn view_error(model: Model) -> Element(Msg) {
  case model.output {
    "" -> element.none()
    message -> html.pre([attr.class("output")], [html.text(message)])
  }
}

fn view_controls(model: Model) -> Element(Msg) {
  html.div([attr.class("controls")], [
    html.label([attr.class("control")], [
      html.span([attr.class("control-label")], [html.text("Drawing")]),
      view_drawing_select(model),
    ]),
    html.button(
      [
        attr.class("text-btn"),
        attr.type_("button"),
        event.on_click(PromptNewDrawing),
      ],
      [html.text("New drawing")],
    ),
    view_shape_slider(model),
    view_speed_slider(model),
    view_timeline(model),
  ])
}

fn view_drawing_select(model: Model) -> Element(Msg) {
  html.select(
    [
      attr.class("drawing-select"),
      attr.attribute("data-test-id", "drawing-select"),
      attr.value(model.active),
      event.on_change(SelectDrawing),
      event.on_input(SelectDrawing),
    ],
    list.map(model.drawings, fn(drawing) {
      let #(name, _source) = drawing
      html.option([attr.value(name), attr.selected(name == model.active)], name)
    }),
  )
}

fn view_shape_slider(model: Model) -> Element(Msg) {
  html.label([attr.class("control")], [
    html.span([attr.class("control-label")], [
      html.text("Shape " <> int.to_string(model.shape_slider)),
    ]),
    html.input([
      attr.type_("range"),
      attr.min(int.to_string(min_shape)),
      attr.max(int.to_string(max_shape)),
      attr.step("1"),
      attr.value(int.to_string(model.shape_slider)),
      attr.attribute("data-test-id", "shape-slider"),
      event.on_input(SetShapeText),
      event.on_change(SetShapeText),
    ]),
  ])
}

fn view_timeline(model: Model) -> Element(Msg) {
  let label =
    "Time "
    <> format_seconds(model.timeline)
    <> " / "
    <> format_seconds(model.duration)
    <> " s"
  let pause = case model.speed == 0.0 {
    True -> "Resume"
    False -> "Pause"
  }
  html.div([attr.class("timeline-row")], [
    html.button(
      [
        attr.class("text-btn"),
        attr.type_("button"),
        attr.attribute("data-test-id", "timeline-pause"),
        event.on_click(TogglePause),
      ],
      [html.text(pause)],
    ),
    html.label([attr.class("control timeline-slider")], [
      html.span([attr.class("control-label")], [html.text(label)]),
      html.input([
        attr.type_("range"),
        attr.min("0"),
        attr.max(float.to_string(model.duration)),
        attr.step("0.1"),
        attr.value(float.to_string(model.timeline)),
        attr.attribute("data-test-id", "timeline-slider"),
        event.on_input(SetTimeline),
        event.on_change(fn(_) { ReleaseTimeline }),
      ]),
    ]),
  ])
}

fn format_seconds(tenths: Float) -> String {
  float.to_string(round_tenth(tenths /. 10.0))
}

fn view_speed_slider(model: Model) -> Element(Msg) {
  html.label([attr.class("control")], [
    html.span([attr.class("control-label")], [
      html.text("Speed " <> float.to_string(model.speed)),
    ]),
    html.input([
      attr.type_("range"),
      attr.min(float.to_string(min_speed)),
      attr.max(float.to_string(max_speed)),
      attr.step("0.1"),
      attr.value(float.to_string(model.speed)),
      attr.attribute("data-test-id", "speed-slider"),
      event.on_input(SetSpeedText),
      event.on_change(SetSpeedText),
    ]),
  ])
}

// The button that brings the code column back, overlaid on the top-left of the
// right pane. Nothing is rendered while the column is already showing (its own
// header holds the button that hides it).
fn view_reveal_code(model: Model) -> Element(Msg) {
  case model.code_open {
    True -> element.none()
    False ->
      html.button(
        [
          attr.class("icon-btn reveal-code"),
          attr.attribute("title", "Show code"),
          event.on_click(ToggleCode),
        ],
        [html.text("⟩")],
      )
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
