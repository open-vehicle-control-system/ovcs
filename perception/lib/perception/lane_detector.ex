defmodule Perception.LaneDetector do
  @roi_height_ratio 2.2
  @polygon_max_y_ratio 1.9

  def detect(mat) do
    height = mat.shape() |> elem(0)
    width = mat.shape() |> elem(1)
    points = [
      [0, height],
      [trunc(width/@roi_height_ratio), trunc(height/@roi_height_ratio)],
      [width, height]
    ]
    gray_image = Evision.cvtColor(mat, Evision.ColorConversionCodes.cv_COLOR_RGB2GRAY)
    cannied_image = Evision.canny(gray_image, 100, 200)
    region = region_of_interest(cannied_image, points) |> Evision.Mat.as_type(:u8)
    detect_lines(region) |> compute_slope |> filter_horizontal
  end

  def region_of_interest(cannied_image, points) do
    mask_layer = Nx.broadcast(0, cannied_image.shape()) |> Evision.Mat.from_nx()
    mask_color = 255
    points_as_mat = points |> Nx.tensor(type: :s32) |> Evision.Mat.from_nx()
    mask_layer = Evision.fillPoly(mask_layer, [points_as_mat], {mask_color})
    img = Evision.Mat.bitwise_and(cannied_image |> Evision.Mat.as_type(:s32), mask_layer)
    img
  end

  def detect_lines(region) do
    lines = Evision.houghLinesP(region, 40, :math.pi()/60, 160)
    case lines do
      {:error, _} -> []
      _ -> lines
    end
  end

  def render(data) do
    mat = Evision.imdecode(data, Evision.Constant.cv_IMREAD_ANYCOLOR())
    lines = Perception.LaneDetector.detect(mat)
    if lines != [] do
      poly_img = Nx.broadcast(Nx.tensor([0], type: :u8), {mat.shape() |> elem(0), mat.shape() |> elem(1)}) |> Evision.Mat.from_nx()
      poly_img = Evision.merge([poly_img, poly_img, poly_img])
      max_y = mat.shape() |> elem(0)
      min_y = trunc(max_y/@polygon_max_y_ratio)
      max_x = mat.shape() |> elem(1)
      min_x = 0
      polygon = Perception.LanePolygon.new(lines, min_y, max_y, min_x, max_x)
      format = ".jpg"
      if(polygon == []) do
        Evision.imencode(format, poly_img)
      else
        points_as_mat = polygon |> Nx.tensor(type: :s32) |> Evision.Mat.from_nx()
        img = Evision.fillPoly(poly_img, [points_as_mat], {0, 255, 0})
        Evision.imencode(format, img)
      end
    end
  end

  defp compute_slope(lines) do
    if lines != [] do
      Enum.map(lines |> Evision.Mat.to_nx() |> Nx.to_list(), fn line ->
        line = line |> Enum.at(0)
          x1 = line |> Enum.at(0)
          y1 = line |> Enum.at(1)
          x2 = line |> Enum.at(2)
          y2 = line |> Enum.at(3)
          slope = if (x2-x1) != 0, do: (y2-y1)/(x2-x1), else: 0
          boundary = if slope <= 0, do: :left, else: :right
          %{x1: x1, x2: x2, y1: y1, y2: y2, slope: slope, boundary: boundary}
        end
      )
    else
      []
    end
  end

  defp filter_horizontal(lines) do
    lines |> Enum.filter(fn line ->
      abs(line.slope) > 0.2 && abs(line.slope) < 1
    end
    )
  end
end
