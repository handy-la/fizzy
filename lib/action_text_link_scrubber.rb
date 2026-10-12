class ActionTextLinkScrubber < Rails::HTML::PermitScrubber
  protected
    def scrub_attributes(node)
      super

      if node.name == "a" && (node["target"] || node["rel"])
        node["rel"] = "noopener noreferrer"
        node.remove_attribute("target") unless node["target"] == "_blank"
      end
    end
end
