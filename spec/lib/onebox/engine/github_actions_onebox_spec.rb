# frozen_string_literal: true

RSpec.describe Onebox::Engine::GithubActionsOnebox do
  describe "PR check run" do
    before do
      @link = "https://github.com/discourse/discourse/pull/13128/checks?check_run_id=2660861130"
      @pr_run_uri = "https://api.github.com/repos/discourse/discourse/pulls/13128"
      @run_uri = "https://api.github.com/repos/discourse/discourse/check-runs/2660861130"

      stub_request(:get, @pr_run_uri).to_return(
        status: 200,
        body: onebox_response("githubactions_pr"),
      )

      stub_request(:get, @run_uri).to_return(
        status: 200,
        body: onebox_response("githubactions_pr_run"),
      )
    end

    include_context "with engines"
    it_behaves_like "an engine"

    describe "#to_html" do
      it "includes status" do
        expect(html).to include("success")
      end

      it "includes title" do
        expect(html).to include("simplify post and topic deletion language")
      end
    end

    context "when github_onebox_access_token is configured" do
      before { SiteSetting.github_onebox_access_token = "1234" }

      it "sends it as part of the request" do
        html
        expect(WebMock).to have_requested(:get, @run_uri).with(
          headers: {
            "Authorization" => "Bearer #{SiteSetting.github_onebox_access_token}",
          },
        )
      end
    end
  end

  describe "GitHub Actions run" do
    before do
      @link = "https://github.com/discourse/discourse/actions/runs/873214216"
      @pr_run_uri = "https://api.github.com/repos/discourse/discourse/actions/runs/873214216"

      stub_request(:get, @pr_run_uri).to_return(
        status: 200,
        body: onebox_response("githubactions_actions_run"),
      )
    end

    include_context "with engines"
    it_behaves_like "an engine"

    describe "#to_html" do
      it "includes status" do
        expect(html).to include("success")
      end

      it "includes title" do
        expect(html).to include("Remove deleted_by_author key")
      end

      it "includes action name" do
        expect(html).to include("Linting")
      end
    end

    context "when github_onebox_access_token is configured" do
      before { SiteSetting.github_onebox_access_token = "1234" }

      it "sends it as part of the request" do
        html
        expect(WebMock).to have_requested(:get, @pr_run_uri).with(
          headers: {
            "Authorization" => "Bearer #{SiteSetting.github_onebox_access_token}",
          },
        )
      end
    end
  end
end
