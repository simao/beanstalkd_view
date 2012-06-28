var App = (function ($, ich) {

  var App = {
    fn: {}
  };

  App.fn.addTableData = function(render_elements, serverData) {
    var attach_rendered_templates = function(render_element, data, transform_func) {
      transform_func = transform_func || function (name, data) { return data; };
      var tbody = $("<tbody></tbody>");
      var $table = render_element.$table;

      $.each(data, function (name, element) {
        element = transform_func(name, element);
        tbody.append(ich[render_element.template_id](element));
      });

      $("tbody", $table).html(tbody.html());
    };

    attach_rendered_templates(render_elements.tubes, serverData.tubes);

    attach_rendered_templates(render_elements.workers, serverData.workers, function (name, stat) {
      return {
        "name": name,
        "value": stat
      };
    });
  };

  App.fn.buildRefreshFunc = function (render_elements, $updated_at, endpoint) {
    return function() {
      App.fn.refresh(render_elements, $updated_at, endpoint);
    };
  };

  App.fn.refresh = function (render_elements, $updated_at, endpoint) {
    return $.ajax({
      'url': endpoint,
      'dataType': 'JSON'
    }).success(function (data) {
      App.fn.addTableData(render_elements, data);

      $updated_at.fadeOut(function () {
        $updated_at.text(new Date().toUTCString()).fadeIn();
      });
    });
  };

  return App;
})($, ich);
