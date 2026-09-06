require "test_helper"

class PassportsTest < ActionDispatch::IntegrationTest
  FORM = {
    "en" => { "schema" => { "properties" => { "watt" => { "type" => "integer" }, "colour" => { "type" => "string" } } }, "ui" => {} }
  }.freeze

  test "a passport is filled in against its type and saved with the answers" do
    with_open_vault do
      create_and_unlock
      type = create_type

      without_validation do
        post passports_path, params: {
          product_type_id: type.id,
          passport: { label: "Batch 1" },
          answers: { watt: 9, colour: "warm white" }.to_json
        }
      end

      assert_redirected_to edit_passport_path(Passport.last)
      passport = Passport.last
      assert_equal "Batch 1", passport.label
      assert_equal({ "watt" => 9, "colour" => "warm white" }, passport.values)
      assert_equal "draft", passport.status
    end
  end

  # The answers travel through the browser as one JSON string. A broken one is
  # not a reason to lose the name the operator typed, and certainly not a reason
  # to raise: it means the form said something unexpected, and the passport is
  # still theirs.
  test "answers that are not usable json cost the answers, not the passport" do
    with_open_vault do
      create_and_unlock
      type = create_type

      without_validation do
        post passports_path, params: { product_type_id: type.id, passport: { label: "Batch 2" }, answers: "{not json" }
      end

      assert_redirected_to edit_passport_path(Passport.last)
      assert_equal({}, Passport.last.values)
    end
  end

  # A draft that does not satisfy the structure is still saved. Refusing it
  # would lose half-finished work to enforce a rule that only has to hold when
  # the passport is submitted.
  test "a draft that does not satisfy the structure is saved and the shortfall is said" do
    with_open_vault do
      create_and_unlock
      type = create_type

      result = Soya::Validation::Result.new(valid: false,
                                            problems: [ "watt is required", "colour must be one of warm, cold" ])
      stubbing(Soya::Validation, :check, ->(*) { result }) do
        post passports_path, params: { product_type_id: type.id, passport: { label: "Batch 3" }, answers: "{}" }
      end

      assert_equal 1, Passport.count
      assert_equal result.problems, flash[:problems],
        "a count tells the operator that something is wrong and nothing about what"

      follow_redirect!
      assert_select ".flash.notice li", text: "watt is required"
    end
  end

  # SHACL can say a great deal about one bad answer. A flash message is not a
  # report, so the list is cut — and says that it was.
  test "a long list of problems is cut short and says so" do
    with_open_vault do
      create_and_unlock
      type = create_type

      many = (1..12).map { |n| "problem #{n}" }
      result = Soya::Validation::Result.new(valid: false, problems: many)
      stubbing(Soya::Validation, :check, ->(*) { result }) do
        post passports_path, params: { product_type_id: type.id, passport: { label: "Batch 3b" }, answers: "{}" }
      end

      shown = flash[:problems]
      assert_equal PassportsController::SHOWN_PROBLEMS + 1, shown.size
      assert_equal "problem 8", shown[PassportsController::SHOWN_PROBLEMS - 1]
      assert_match(/4/, shown.last)
    end
  end

  test "a passport cannot be started without saying which kind it is" do
    with_open_vault do
      create_and_unlock
      get new_passport_path
      assert_redirected_to passports_path
    end
  end

  test "a type that was never fetched cannot start a passport: there would be no form" do
    with_open_vault do
      create_and_unlock
      type = ProductType.create!(label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example")

      get new_passport_path(product_type_id: type.id)
      assert_redirected_to passports_path
    end
  end

  test "the form page embeds soya-form with the structure, the language and the answers" do
    with_open_vault do
      create_and_unlock
      type = create_type
      passport = Passport.create!(product_type: type, label: "Batch 4", values: { "watt" => 9 })

      get edit_passport_path(passport)
      assert_response :success

      frame = response.body[/src="(\/soya-form\/[^"]+)"/, 1]
      assert frame, "there is no form frame on the page"
      assert_select ".soya-frame-wrap > iframe.soya-frame", 1,
        "the frame needs the wrapper: its own page draws to its edges and cannot be styled from here"

      query = Rack::Utils.parse_query(URI.parse(CGI.unescapeHTML(frame)).query)
      assert_equal type.resolvable_name, query["schemaDri"]
      assert_equal "form-only", query["viewMode"], "the operator must not be shown soya-form's own schema picker"
      assert_equal({ "watt" => 9 }, JSON.parse(query["data"]))
    end
  end

  test "the summary shows the fields the structure knows and skips the empty ones" do
    with_open_vault do
      type = create_type
      passport = Passport.create!(product_type: type, label: "Batch 5",
        values: { "watt" => 9, "colour" => "", "leftover" => "from an older structure" })

      assert_equal [ [ "watt", "9" ] ], passport.summary
    end
  end

  # The rule that is invisible until it fails: for a GS1 Digital Link the path
  # expresses the granularity, and the service refuses a declaration that
  # contradicts it. Catching it here means the operator sees it next to the two
  # fields that disagree, not as a rejected submission.
  test "a granularity that contradicts the identifier path is refused with the reason" do
    with_open_vault do
      create_and_unlock
      type = create_type

      without_validation do
        post passports_path, params: {
          product_type_id: type.id,
          passport: { label: "Batch 6",
                      unique_product_identifier: "https://id.example.com/01/09520123456788/21/000123",
                      granularity: "model" },
          answers: "{}"
        }
      end

      assert_response :unprocessable_entity
      assert_equal 0, Passport.count
      assert_match(/item/, response.body, "the message has to name what the path actually says")
    end
  end

  test "an identifier the carrier cannot bear is refused before it reaches the service" do
    with_open_vault do
      create_and_unlock
      type = create_type

      without_validation do
        post passports_path, params: {
          product_type_id: type.id,
          passport: { label: "Batch 7", unique_product_identifier: "http://id.example.com/01/09520123456788" },
          answers: "{}"
        }
      end

      assert_response :unprocessable_entity
    end
  end

  # A draft is allowed to be unfinished. Demanding the envelope before anything
  # can be saved would mean an operator has to decide the identifier before
  # typing the first product datum.
  test "a draft without an envelope is still a draft" do
    with_open_vault do
      create_and_unlock
      type = create_type

      without_validation do
        post passports_path, params: { product_type_id: type.id, passport: { label: "Batch 8" }, answers: "{}" }
      end

      assert_redirected_to edit_passport_path(Passport.last)
      passport = Passport.last
      assert_not passport.envelope_complete?, "nothing was filled in, so it cannot be ready to submit"
    end
  end

  test "an identifier and a matching granularity make the envelope complete" do
    with_open_vault do
      create_and_unlock
      type = create_type
      passport = Passport.create!(product_type: type, label: "Batch 9",
        unique_product_identifier: "https://id.example.com/01/09520123456788/21/000123",
        granularity: "item")

      assert passport.envelope_complete?
      assert_equal "item", passport.identifier.granularity
    end
  end

  # Filling in a passport happens over several sittings, and everything that
  # comes after the form — the identifier, the submission, the custodian — is on
  # that same page. A save that always left it meant walking back in for each of
  # those, so the plain save returns to the passport and only the second button
  # goes to the list.
  test "saving stays on the passport, saving and closing goes back to the list" do
    with_open_vault do
      create_and_unlock
      type = create_type

      without_validation do
        post passports_path, params: { product_type_id: type.id, passport: { label: "Batch 9" }, answers: "{}" }
      end
      passport = Passport.last
      assert_redirected_to edit_passport_path(passport)

      without_validation do
        patch passport_path(passport), params: { passport: { label: "Batch 9" }, answers: "{}" }
      end
      assert_redirected_to edit_passport_path(passport)

      without_validation do
        patch passport_path(passport), params: { passport: { label: "Batch 9" }, answers: "{}",
                                                 and_close: "Save and close" }
      end
      assert_redirected_to passports_path
    end
  end

  private

  def create_type
    ProductType.create!(
      label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}', forms: FORM.to_json, fetched_at: Time.current
    )
  end

  # Validation goes through soya-web-cli, which is a separate process and not
  # running in the test environment. What is under test here is the passport,
  # not the check.
  def without_validation(&block) = stubbing(Soya::Validation, :check, ->(*) { nil }, &block)
end
