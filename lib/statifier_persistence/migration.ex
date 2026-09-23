defmodule StatifierPersistence.Migration do
  @moduledoc """
  Moving a waiting execution from one chart onto another, on purpose.

  An execution is pinned to the chart it started on: its stored row carries
  that chart's content hash, and the identity guard refuses to load its
  position against any other machine. A migration is the explicit act that
  re-pins it. It is decided in this package's ADR-0013
  (`docs/adr/0013-the-migration-plan.md`): a plan is data, one plan per pair
  of chart hashes; it is a transform over the engine's position export,
  applied by the engine's import on the new machine; it is checked twice,
  once against the two machines and once against the execution; and it
  either re-pins the execution whole or leaves it as it was.

  `StatifierPersistence.Migration.Plan` is the plan: its struct, its one
  JSON-safe map encoding, and the static validation against the two
  machines. Nothing in this package migrates an execution because a chart
  was saved, created against or published.

  ## Not the table migrations

  This namespace is about executions, not tables.
  `StatifierPersistence.Ecto.Migrations` is the schema-migration helper a
  host runs to create and upgrade this package's tables; it moves no
  execution between charts, and nothing here touches a table's shape.
  """
end
