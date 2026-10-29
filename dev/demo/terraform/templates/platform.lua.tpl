return {
  agent_provider = "vertex",
  vertex_project = "${vertex_project}",
  vertex_region = "${vertex_region}",
%{ if agent_model != "" ~}
  agent_model = "${agent_model}",
%{ endif ~}
  -- No search_provider (no internet_search tool) and no mail_provider
  -- (no invites or password resets): admins set passwords on /admin-users.
  public_url = "https://${domain}",
}
