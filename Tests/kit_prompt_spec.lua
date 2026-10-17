local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local FILES = { "Theme", "Window", "Widgets", "Prompt" }

describe("Kit.Prompt", function()
    local Kit, dialog, results

    local function type_(text)
        dialog.input:SetText(text)
        dialog.input.scripts.OnTextChanged(dialog.input)
    end

    local function open(config)
        config.onOK = config.onOK or function(text, choice)
            results[#results + 1] = { text, choice }
        end
        dialog:Open(config)
    end

    before_each(function()
        mock.reset()
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        local ns = {}
        for _, name in ipairs(FILES) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        Kit = ns.Kit
        results = {}
        dialog = Kit.Prompt("TestPrompt")
    end)

    after_each(function()
        mock.teardown()
    end)

    it("gives the same window for the same name", function()
        assert.are.equal(dialog, Kit.Prompt("TestPrompt"))
        assert.are_not.equal(dialog, Kit.Prompt("OtherPrompt"))
    end)

    it("is closed by Escape", function()
        local found
        for _, name in ipairs(UISpecialFrames) do
            found = found or name == "TestPrompt"
        end
        assert.is_true(found)
    end)

    it("shows the title, the label and the start text", function()
        open({ title = "New thing", label = "Name", text = "Start" })
        assert.is_true(dialog:IsShown())
        assert.are.equal("New thing", dialog.title)
        assert.are.equal("Name", dialog.label:GetText())
        assert.are.equal("Start", dialog.input:GetText())
        assert.is_true(dialog.okButton.enabled)
        assert.is_false(dialog.choice:IsShown())
    end)

    it("turns OK off while the trimmed text is empty", function()
        open({ label = "Name" })
        assert.is_false(dialog.okButton.enabled)
        type_("   ")
        assert.is_false(dialog.okButton.enabled)
        type_("A")
        assert.is_true(dialog.okButton.enabled)
    end)

    it("sends the trimmed text on OK and closes", function()
        open({})
        type_("  Hello  ")
        dialog.okButton.scripts.OnClick(dialog.okButton)
        assert.are.same({ { "Hello" } }, results)
        assert.is_false(dialog:IsShown())
    end)

    it("does nothing on OK with an empty text", function()
        open({})
        dialog.okButton.scripts.OnClick(dialog.okButton)
        assert.are.same({}, results)
        assert.is_true(dialog:IsShown())
    end)

    it("treats Enter as OK", function()
        open({})
        type_("Hello")
        dialog.input.scripts.OnEnterPressed(dialog.input)
        assert.are.same({ { "Hello" } }, results)
        assert.is_false(dialog:IsShown())
    end)

    it("treats Escape in the box and Cancel as cancel", function()
        open({})
        type_("Hello")
        dialog.input.scripts.OnEscapePressed(dialog.input)
        assert.is_false(dialog:IsShown())
        open({})
        type_("Hello")
        dialog.cancelButton.scripts.OnClick(dialog.cancelButton)
        assert.is_false(dialog:IsShown())
        assert.are.same({}, results)
    end)

    it("shows a validate error under the box and turns OK off", function()
        open({
            validate = function(text)
                return text == "bad" and "this name is bad" or nil
            end,
        })
        type_("bad")
        assert.are.equal("this name is bad", dialog.error:GetText())
        assert.is_false(dialog.okButton.enabled)
        dialog.input.scripts.OnEnterPressed(dialog.input)
        assert.are.same({}, results)
        type_("good")
        assert.are.equal("", dialog.error:GetText())
        assert.is_true(dialog.okButton.enabled)
    end)

    it("keeps the window open and shows the text that onOK gives", function()
        open({
            onOK = function()
                return "refused"
            end,
        })
        type_("A")
        dialog.okButton.scripts.OnClick(dialog.okButton)
        assert.is_true(dialog:IsShown())
        assert.are.equal("refused", dialog.error:GetText())
        type_("B")
        assert.are.equal("", dialog.error:GetText())
    end)

    it("shows a choice list above the box and sends the choice", function()
        open({
            choices = { { value = "a", text = "Alpha" }, { value = "b", text = "Beta" } },
            choiceLabel = "Kind",
            label = "Name",
        })
        assert.is_true(dialog.choice:IsShown())
        assert.are.equal("Kind", dialog.choiceLabel:GetText())
        assert.are.equal("a", dialog.choice:GetValue())
        dialog.choice.menuItems[2].pick()
        type_("X")
        dialog.okButton.scripts.OnClick(dialog.okButton)
        assert.are.same({ { "X", "b" } }, results)
    end)

    it("starts with the given choice and drops the choice list at the next open without choices", function()
        open({ choices = { { value = "a", text = "Alpha" }, { value = "b", text = "Beta" } }, choice = "b" })
        assert.are.equal("b", dialog.choice:GetValue())
        dialog.cancelButton.scripts.OnClick(dialog.cancelButton)
        open({})
        assert.is_false(dialog.choice:IsShown())
    end)
end)
