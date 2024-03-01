defmodule VmsApiWeb.Api.SamplesController do
  use VmsApiWeb, :controller

  def index(conn, _params) do
    with :ok <- :ok do
      samples = [%{id: 1, name: "sample1"}, %{id: 2, name: "sample2"}, %{id: 3, name: "sample3"}]
      conn
      |> put_status(:ok)
      |> render("index.json", %{samples: samples, other_var: "val_index"})
    else
      {:error, error} -> conn
      |> put_status(:bad_request)
      |> render("error.json", error: error)
    end
  end

  def show(conn, %{"id" => id} = _params) do

    with :ok <- :ok do
      sample = %{id: id, name: "sample#{id}"}
      conn
      |> put_status(:ok)
      |> render("show.json", %{sample: sample, other_var: "val_show"})
    else
      {:error, error} -> conn
      |> put_status(:bad_request)
      |> render("error.json", error: error)
    end
  end
end
