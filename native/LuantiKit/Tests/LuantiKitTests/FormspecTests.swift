import XCTest
import simd
@testable import LuantiKit

/// Formspec list[] parsing — enough to drive the spatial container UI.
final class FormspecTests: XCTestCase {
    func testParsesPlayerAndNodeLists() {
        // A VoxeLibre chest formspec: the chest's own list (current_name) + the
        // player's main inventory and hotbar.
        let spec = "size[9,8.75]list[current_name;main;0,0.3;9,3;]list[current_player;main;0,4.5;9,3;9]list[current_player;main;0,7.74;9,1;]"
        let lists = Formspec.parseLists(spec, context: SIMD3(10, -5, 20))
        XCTAssertEqual(lists.count, 3)
        XCTAssertEqual(lists[0].loc, "nodemeta:10,-5,20")   // current_name -> context node
        XCTAssertEqual(lists[0].list, "main")
        XCTAssertEqual(lists[0].cols, 9); XCTAssertEqual(lists[0].rows, 3)
        XCTAssertEqual(lists[0].gy, 0.3, accuracy: 1e-4)
        XCTAssertEqual(lists[1].loc, "current_player")
        XCTAssertEqual(lists[1].start, 9)                   // hotbar offset skipped
        XCTAssertEqual(lists[2].start, 0)
    }

    func testFurnaceLists() {
        let spec = "list[context;src;2.75,0.5;1,1;]list[context;fuel;2.75,2.5;1,1;]list[context;dst;5.75,1.5;2,2;]"
        let lists = Formspec.parseLists(spec, context: SIMD3(0, 0, 0))
        XCTAssertEqual(lists.map { $0.list }, ["src", "fuel", "dst"])
        XCTAssertEqual(lists[2].cols, 2); XCTAssertEqual(lists[2].rows, 2)
        XCTAssertTrue(lists.allSatisfy { $0.loc == "nodemeta:0,0,0" })
    }

    func testNoListsWhenContextMissing() {
        // current_name with no context node -> that list is dropped, not crashed.
        let lists = Formspec.parseLists("list[current_name;main;0,0;9,3;]", context: nil)
        XCTAssertTrue(lists.isEmpty)
    }

    func testParsesSignTextField() {
        let spec = "size[5,3]field[0.3,0.3;5,2;text;;hello world]button_exit[2,2;1,1;;Write]"
        let fields = Formspec.parseFields(spec)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].name, "text")
        XCTAssertEqual(fields[0].value, "hello world")
        XCTAssertTrue(Formspec.parseLists(spec, context: nil).isEmpty)
    }
}

extension FormspecTests {
    func testParseButtonsFindsLeaveBed() {
        // The mcl_beds sleep form: a size + a label + the Leave bed button.
        let spec = "size[8,4]label[0,0;Good night]button_exit[4,3;4,0.75;leave;Leave bed]"
        let btns = Formspec.parseButtons(spec)
        XCTAssertTrue(btns.contains { $0.name == "leave" && $0.label == "Leave bed" })
    }
    func testBedFormIsNotATextEditor() {
        // VoxeLibre's current sleep form (device log 2026-09-22): a chat field,
        // a Send button and the Leave bed exit button. Not a sign.
        let bed = "size[12,5;true]field[0.3,4.5;10,1;chatmessage;Chat:;]button[10,3.73;2,2;chatsubmit;Send]" +
                  "bgcolor[#000000FF;true]button_exit[4,1.5;4,1.5;leave;Leave bed]label[4,0.5;You're sleeping.]"
        XCTAssertFalse(Formspec.isTextEditorForm(bed))
        // mcl_signs: textarea + a Done exit button -> keyboard.
        let sign = "size[6,3]textarea[0.25,0.25;6,1.5;text;Enter sign text:;hi]label[0,1.5;Max]button_exit[0,2.4;6,1;submit;Done]"
        XCTAssertTrue(Formspec.isTextEditorForm(sign))
        // A bare field with only a submit exit button is still an editor.
        XCTAssertTrue(Formspec.isTextEditorForm("size[6,2]field[0,0;6,1;text;Name;]button_exit[0,1;6,1;submit;OK]"))
        XCTAssertFalse(Formspec.isTextEditorForm("size[6,2]label[0,0;Hi]button_exit[0,1;6,1;leave;Leave]"))
    }
    func testParseButtonsIgnoresFields() {
        let spec = "field[0,0;3,1;name;Label;]"
        XCTAssertTrue(Formspec.parseButtons(spec).isEmpty)
    }
}

/// the death screen's "Respawn" button label arrives translator-wrapped
/// (\x1b(T@__builtin)Respawn\x1b(E)); parseButtons must return clean text so the
/// notice doesn't show raw escape characters.
final class FormspecCleanTests: XCTestCase {
    func testTranslatorWrappedButtonLabelIsClean() {
        let esc = "\u{1b}"
        let spec = "button_exit[4,3;3,0.5;btn_respawn;\(esc)(T@__builtin)Respawn\(esc)(E)]"
        let buttons = Formspec.parseButtons(spec)
        XCTAssertEqual(buttons.first?.name, "btn_respawn")
        XCTAssertEqual(buttons.first?.label, "Respawn")
    }

    func testCleanUndoesFormspecEscape() {
        // formspec_escape turns "a,b" into "a\,b"; clean() puts it back.
        XCTAssertEqual(Formspec.clean("a\\,b\\;c"), "a,b;c")
    }

    func testCleanStripsColorAndTranslationMarkers() {
        let esc = "\u{1b}"
        XCTAssertEqual(Formspec.clean("\(esc)(c@#ff0000)Slain\(esc)(c@#ffffff)"), "Slain")
    }

    func testCleanLeavesPlainTextAlone() {
        XCTAssertEqual(Formspec.clean("Respawn"), "Respawn")
    }
}

/// static label[] text (station name + slot captions) is parsed so an
/// otherwise-bare station UI has something readable.
final class FormspecLabelTests: XCTestCase {
    func testParsesLabelPositionAndText() {
        let spec = "size[8,9]label[0.5,0.5;Cartography Table]list[context;input;2,2;1,1;]"
        let labels = Formspec.parseLabels(spec)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.first?.text, "Cartography Table")
        XCTAssertEqual(labels.first?.gx ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(labels.first?.gy ?? -1, 0.5, accuracy: 1e-6)
    }
    func testIgnoresVertlabelSuffix() {
        // "vertlabel[" ends in "label[" but is a different element; don't match it.
        let spec = "vertlabel[0,0;SIDE]label[1,1;Top]"
        let labels = Formspec.parseLabels(spec)
        XCTAssertEqual(labels.map { $0.text }, ["Top"])
    }
    func testCleansEscapedLabelText() {
        let spec = "label[0,0;Fuel\\, Coal]"
        XCTAssertEqual(Formspec.parseLabels(spec).first?.text, "Fuel, Coal")
    }
    func testDropsEmptyLabel() {
        XCTAssertTrue(Formspec.parseLabels("label[0,0;]").isEmpty)
    }

    // The anvil form: item lists PLUS a rename field, so the field must be
    // parsed with position so a tappable box can be placed in the panel.
    func testParsesPositionedField() {
        let spec = "field[4.125,0.75;7.25,1;name;;Sword]list[context;input;1.625,2.6;1,1;]"
        let fields = Formspec.parseFieldsPositioned(spec)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.name, "name")
        XCTAssertEqual(fields.first?.value, "Sword")
        XCTAssertEqual(fields.first?.gx ?? -1, 4.125, accuracy: 1e-6)
        XCTAssertEqual(fields.first?.gy ?? -1, 0.75, accuracy: 1e-6)
        XCTAssertEqual(fields.first?.w ?? -1, 7.25, accuracy: 1e-6)
    }
    func testPositionedFieldSkipsBareField() {
        // A positionless field[name;label;default] is a pure text dialog, not a box.
        XCTAssertTrue(Formspec.parseFieldsPositioned("field[text;;hi]").isEmpty)
    }
    func testParsesPositionedButtons() {
        let spec = "button[1,2;3,1;save;Save]button_exit[5,2;3,1;quit;Done]"
        let bs = Formspec.parseButtonsPositioned(spec)
        XCTAssertEqual(bs.count, 2)
        XCTAssertEqual(bs[0].name, "save"); XCTAssertEqual(bs[0].label, "Save"); XCTAssertFalse(bs[0].exit)
        XCTAssertEqual(bs[1].name, "quit"); XCTAssertEqual(bs[1].label, "Done"); XCTAssertTrue(bs[1].exit)
        XCTAssertEqual(bs[0].gx, 1, accuracy: 1e-6)
        XCTAssertEqual(bs[0].w, 3, accuracy: 1e-6)
    }
    func testParsesPositionedImageButton() {
        // image_button[x,y;w,h;texture;name;label] -> name second-to-last.
        let bs = Formspec.parseButtonsPositioned("image_button[0,0;2,2;t.png;go;Go]")
        XCTAssertEqual(bs.first?.name, "go")
        XCTAssertEqual(bs.first?.label, "Go")
    }

    // the furnace fire gauge / cook arrow are image[] elements whose
    // texture is a modifier chain; parse position, size, and the whole texture.
    func testParsesImageWithModifierTexture() {
        let spec = "image[3.5,2;1,1;default_furnace_fire_bg.png^[lowpart:40:default_furnace_fire_fg.png]" +
                   "list[context;src;3.5,0.75;1,1;]"
        let imgs = Formspec.parseImages(spec)
        XCTAssertEqual(imgs.count, 1)
        XCTAssertEqual(imgs.first?.gx ?? -1, 3.5, accuracy: 1e-6)
        XCTAssertEqual(imgs.first?.w ?? -1, 1, accuracy: 1e-6)
        XCTAssertEqual(imgs.first?.texture, "default_furnace_fire_bg.png^[lowpart:40:default_furnace_fire_fg.png")
    }
    func testImageDoesNotMatchImageButtonOrBackground() {
        // image_button[ and background9[ must not be parsed as image[.
        let spec = "image_button[0,0;1,1;t.png;go;Go]background9[0,0;5,5;bg.png;1]"
        XCTAssertTrue(Formspec.parseImages(spec).isEmpty)
    }

    // item_image[] is an item icon, distinct from image[] (a texture).
    func testParsesItemImageNotImage() {
        let spec = "item_image[1,2;1,1;mcl_core:diamond]image[3.5,2;1,1;fire.png]"
        let items = Formspec.parseItemImages(spec)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.texture, "mcl_core:diamond")
        XCTAssertTrue(items.first?.isItem ?? false)
        // The plain image[] parser must NOT grab item_image[].
        let imgs = Formspec.parseImages(spec)
        XCTAssertEqual(imgs.map { $0.texture }, ["fire.png"])
        XCTAssertFalse(imgs.first?.isItem ?? true)
    }
    func testItemImageIgnoresItemImageButton() {
        // item_image_button[ must not be parsed as item_image[.
        let spec = "item_image_button[0,0;1,1;mcl_core:stone;go;Go]"
        XCTAssertTrue(Formspec.parseItemImages(spec).isEmpty)
    }
    // image_button[] keeps its icon texture at f[2].
    func testImageButtonKeepsTexture() {
        let bs = Formspec.parseButtonsPositioned("image_button[5.2,1.5;1,1;mcl_potions_swift.png;swiftness;]")
        XCTAssertEqual(bs.first?.name, "swiftness")
        XCTAssertEqual(bs.first?.texture, "mcl_potions_swift.png")
        // A plain button has no texture.
        let pb = Formspec.parseButtonsPositioned("button[1,2;3,1;save;Save]")
        XCTAssertEqual(pb.first?.texture, "")
    }

    // container[x,y] shifts contained elements by a running offset, then
    // the markers are dropped; nested containers add up; container_end pops.
    func testFlattenContainerOffsetsPositions() {
        let spec = "container[4,2]button[0,0;7,1;a;A]image[0,1;1,1;t.png]container_end[]" +
                   "button[1,1;2,1;b;B]"
        let flat = Formspec.flattenContainers(spec)
        // Inside the container: 0,0 -> 4,2 and 0,1 -> 4,3.
        let bs = Formspec.parseButtonsPositioned(flat)
        XCTAssertEqual(bs.count, 2)
        XCTAssertEqual(bs[0].gx, 4, accuracy: 1e-4); XCTAssertEqual(bs[0].gy, 2, accuracy: 1e-4)
        // Outside the container: unchanged.
        XCTAssertEqual(bs[1].gx, 1, accuracy: 1e-4); XCTAssertEqual(bs[1].gy, 1, accuracy: 1e-4)
        let im = Formspec.parseImages(flat).first
        XCTAssertEqual(im?.gx ?? -1, 4, accuracy: 1e-4); XCTAssertEqual(im?.gy ?? -1, 3, accuracy: 1e-4)
        // The container markers are gone.
        XCTAssertFalse(flat.contains("container["))
    }
    func testFlattenNestedContainers() {
        let spec = "container[1,1]container[2,3]label[0,0;deep]container_end[]label[0,0;shallow]container_end[]"
        let flat = Formspec.flattenContainers(spec)
        let labels = Formspec.parseLabels(flat)
        // deep: 1+2, 1+3 = 3,4 ; shallow: 1,1
        XCTAssertEqual(labels.first(where: { $0.text == "deep" })?.gx ?? -1, 3, accuracy: 1e-4)
        XCTAssertEqual(labels.first(where: { $0.text == "deep" })?.gy ?? -1, 4, accuracy: 1e-4)
        XCTAssertEqual(labels.first(where: { $0.text == "shallow" })?.gx ?? -1, 1, accuracy: 1e-4)
    }
    func testFlattenNoContainerIsUnchanged() {
        let spec = "list[current_player;main;0,5;9,3;9]label[0.5,0.5;Hi]"
        XCTAssertEqual(Formspec.flattenContainers(spec), spec)
    }

    // item_image_button[] carries an item icon + a submit field, and must
    // NOT be parsed as a plain button/image_button.
    func testParsesItemImageButton() {
        let spec = "item_image_button[1,2;0.875,0.875;mcl_core:stonebrick;recipe_3;]" +
                   "button[5,5;2,1;done;Done]"
        let its = Formspec.parseItemImageButtons(spec)
        XCTAssertEqual(its.count, 1)
        XCTAssertEqual(its.first?.name, "recipe_3")
        XCTAssertEqual(its.first?.itemName, "mcl_core:stonebrick")
        XCTAssertEqual(its.first?.gx ?? -1, 1, accuracy: 1e-4)
        // The plain-button parser must skip item_image_button but keep the real one.
        let bs = Formspec.parseButtonsPositioned(spec)
        XCTAssertEqual(bs.map { $0.name }, ["done"])
    }

    // tooltip[element;text] maps a widget name to hover text; the rectangle
    // form tooltip[x,y;w,h;text] is skipped.
    func testParsesElementTooltip() {
        // Real tooltips carry an actual newline (Lua's \n), not an escaped one.
        let spec = "tooltip[button_i;Sharpness\nCosts 3 levels]tooltip[1,2;3,1;area tip]"
        let t = Formspec.parseTooltips(spec)
        XCTAssertEqual(t["button_i"]?.text, "Sharpness\nCosts 3 levels")
        XCTAssertNil(t["button_i"]?.color)   // plain text, no color escape
        XCTAssertNil(t["1,2"])            // rectangle form not captured
        XCTAssertEqual(t.count, 1)
    }

    // checkbox[x,y;name;label;selected] with selected state.
    func testParsesCheckbox() {
        let cbs = Formspec.parseCheckboxes("checkbox[5.15,5.25;clear_inv_check;Do not ask again;true]")
        XCTAssertEqual(cbs.count, 1)
        XCTAssertEqual(cbs.first?.name, "clear_inv_check")
        XCTAssertEqual(cbs.first?.label, "Do not ask again")
        XCTAssertTrue(cbs.first?.selected ?? false)
        // Default (no selected field) is unchecked.
        XCTAssertFalse(Formspec.parseCheckboxes("checkbox[0,0;c;Label;]").first?.selected ?? true)
    }

    // background9[...;true] (auto_clip fill) + background[...;auto_clip] (fill), vs a
    // plain background[] (positioned art).
    func testParsesBackgrounds() {
        let spec = "background9[1,1;1,1;mcl_base_textures_background9.png;true;7]" +
                   "background[-0.19,-0.25;9.5,9.5;mcl_brewing_inventory.png]"
        let bgs = Formspec.parseBackgrounds(spec)
        XCTAssertEqual(bgs.count, 2)
        XCTAssertEqual(bgs[0].texture, "mcl_base_textures_background9.png")
        XCTAssertTrue(bgs[0].fill)                       // auto_clip true -> fill
        XCTAssertEqual(bgs[1].texture, "mcl_brewing_inventory.png")
        XCTAssertFalse(bgs[1].fill)                      // plain background at coords
        XCTAssertEqual(bgs[1].gx, -0.19, accuracy: 1e-4)
    }
    // background9's 4th field is auto_clip, not draw_border. The creative
    // inventory's own panel leaves it empty and sits at its coordinates.
    func testPositionedBackground9DoesNotFill() {
        let bgs = Formspec.parseBackgrounds("background9[0,1.34;13,8.75;mcl_base_textures_background9.png;;7]")
        XCTAssertEqual(bgs.count, 1)
        XCTAssertFalse(bgs[0].fill)
        XCTAssertEqual(bgs[0].gy, 1.34, accuracy: 1e-4)
    }
    func testNoPrependOptsOut() {
        XCTAssertFalse(Formspec.wantsPrepend("formspec_version[6]no_prepend[]size[13,8.75]"))
        XCTAssertTrue(Formspec.wantsPrepend("formspec_version[4]size[11.75,10.425]"))
    }
    func testBackgroundAutoClipFills() {
        let bgs = Formspec.parseBackgrounds("background[0,0;10,10;bg.png;true]")
        XCTAssertTrue(bgs.first?.fill ?? false)          // auto_clip true -> fill
    }

    // a leading color escape on formspec text is parsed to a packed tint
    // (r + g*256 + b*65536) instead of stripped, so dark labels don't render as
    // invisible white. #313131 = 49 + 49*256 + 49*65536.
    private static let dark313131 = Float(0x31 + 0x31 * 256 + 0x31 * 65536)

    func testLabelKeepsColor() {
        let ls = Formspec.parseLabels("label[0.375,4.7;\u{1b}(c@#313131)Inventory]")
        XCTAssertEqual(ls.first?.text, "Inventory")
        XCTAssertEqual(ls.first?.color, Self.dark313131)
        // A plain label carries no color (renders default white).
        XCTAssertNil(Formspec.parseLabels("label[0,0;Plain]").first?.color)
    }

    func testButtonKeepsColor() {
        let bs = Formspec.parseButtonsPositioned("button[1,2;3,1;go;\u{1b}(c@#313131)Go]")
        XCTAssertEqual(bs.first?.label, "Go")
        XCTAssertEqual(bs.first?.color, Self.dark313131)
    }

    func testCheckboxKeepsColor() {
        let cbs = Formspec.parseCheckboxes("checkbox[0,0;c;\u{1b}(c@#313131)Ask;false]")
        XCTAssertEqual(cbs.first?.label, "Ask")
        XCTAssertEqual(cbs.first?.color, Self.dark313131)
    }

    func testTooltipKeepsColor() {
        let t = Formspec.parseTooltips("tooltip[btn;\u{1b}(c@#313131)Hint]")
        XCTAssertEqual(t["btn"]?.text, "Hint")
        XCTAssertEqual(t["btn"]?.color, Self.dark313131)
    }
}

final class FormspecModelTests: XCTestCase {
    // VoxeLibre's survival inventory (mcl_player.get_player_formspec_model).
    func testParsesPlayerModel() {
        let spec = "size[9,8.75]model[1.57,0.4;3.62,4.85;;mcl_armor_character.b3d;character.png,blank.png,blank.png;0,180;false;false;0,79]list[current_player;main;0,4.5;9,3;9]"
        let m = Formspec.parseModels(spec)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].mesh, "mcl_armor_character.b3d")
        XCTAssertEqual(m[0].textures, ["character.png", "blank.png", "blank.png"])
        XCTAssertEqual(m[0].rotY, 180)
        XCTAssertEqual(m[0].frame, 0)
        XCTAssertEqual(m[0].w, 3.62, accuracy: 1e-4)
    }

    func testEscapedCommaStaysInTexture() {
        let m = Formspec.parseModels("model[0,0;1,1;;a.b3d;x.png^[colorize:#ff0000\\,128,y.png;0,0;false;false;0,0]")
        XCTAssertEqual(m.first?.textures, ["x.png^[colorize:#ff0000,128", "y.png"])
    }

    func testImageTokenDoesNotMatchModel() {
        XCTAssertTrue(Formspec.parseModels("image[0,0;1,1;model[x.png]").isEmpty)
    }
}
