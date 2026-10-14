# Event delivery for the Nest thermostat. Home Assistant's Nest integration
# learns of state changes through a Cloud Pub/Sub subscription; the Device
# Access (SDM) API publishes to a topic we own, after Google retired its own
# hosted topics (deadline 2026-11-30). Home Assistant pulls from the
# subscription by name, so the name here is the one its config entry
# already holds and nothing in Home Assistant changes.
#
# One step lives outside this module: the Device Access Console
# (https://console.nest.google.com/device-access/) has no API, so the
# project's "Pub/Sub topic" must be pointed at google_pubsub_topic.nest_sdm
# by hand after the first apply, replacing the Google-hosted topic.

resource "google_pubsub_topic" "nest_sdm" {
  name = "nest-sdm"
}

# The SDM API publishes as this Google group, per the Device Access
# documentation on self-hosted topics.
resource "google_pubsub_topic_iam_member" "nest_sdm_publisher" {
  topic  = google_pubsub_topic.nest_sdm.name
  role   = "roles/pubsub.publisher"
  member = "group:sdm-publisher@googlegroups.com"
}

resource "google_pubsub_subscription" "homeassistant" {
  name  = "homeassistant"
  topic = google_pubsub_topic.nest_sdm.id

  # Pub/Sub deletes an idle subscription after 31 days by default; an
  # empty TTL turns that off, so a long Home Assistant outage cannot
  # delete the subscription behind it.
  expiration_policy {
    ttl = ""
  }
}
