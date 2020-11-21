import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:postgres/postgres.dart';
import 'package:recase/recase.dart';

import '../core.dart';
import 'pattern_matcher.dart';

enum ObjectRepresentation {
  json,

  // Not fully supported by the driver yet
  typesAndArrays
}

class PostgresBox extends Box {
  final PostgreSQLConnection _connection;
  final ObjectRepresentation objectRepresentation;

  PostgresBox(String hostname, Registry registry,
      {@required String database,
      int port = 5432,
      String username = 'postgres',
      String password = 'postgres',
      this.objectRepresentation = ObjectRepresentation.json})
      : _connection = PostgreSQLConnection(
          hostname,
          port,
          database,
          username: username,
          password: password,
        ),
        super(registry);

  @override
  Future close() => _connection.close();

  @override
  Future deleteAll<T>([Type type]) async {
    var connection = await _openConnection;
    var entitySupport = registry.lookup(type ?? T);
    var tableName = _snakeCase(entitySupport.name);
    return connection.execute('DELETE FROM "$tableName"');
  }

  @override
  Future<T> find<T>(key, [Type type]) async {
    var connection = await _openConnection;
    var entitySupport = registry.lookup(type ?? T);
    var tableName = _snakeCase(entitySupport.name);
    var conditions = entitySupport.keyFields.map((field) => '${_snakeCase(field)} = @$field').join(' AND ');
    var values = key is Map ? key : {entitySupport.keyFields.first: key};
    var results =
        await connection.mappedResultsQuery('SELECT * FROM "$tableName" WHERE $conditions', substitutionValues: values);
    if (results.isNotEmpty) {
      return _mapRow<T>(results.first[tableName], entitySupport, type, [], []);
    }
    return null;
  }

  Stream<T> _query<T>(
    String conditions,
    Map<String, dynamic> bindings,
    Map<String, String> order,
    Type type,
    int limit,
    int offset,
    List<Field> selectFields,
    Map<_Table, String> joins,
  ) async* {
    var connection = await _openConnection;
    var entitySupport = registry.lookup(type ?? T);
    var tableName = _snakeCase(entitySupport.name);
    var orderClause =
        order.isNotEmpty ? 'ORDER BY ${order.entries.map((e) => '${_snakeCase(e.key)} ${e.value}').join(', ')}' : '';
    var sql = 'SELECT * FROM "$tableName"'
        '${joins.isNotEmpty ? joins.entries.map((e) => ' INNER JOIN ${e.key.name} ON ${e.value}').join(' ') : ''}'
        '${conditions.isNotEmpty ? ' WHERE $conditions ' : ' '}'
        '$orderClause '
        'LIMIT $limit OFFSET $offset';
    try {
      var results = await connection.mappedResultsQuery(sql, substitutionValues: bindings);
      for (var result in results) {
        yield _mapRow<T>(result[tableName], entitySupport, type, selectFields, joins.keys);
      }
    } catch (e) {
      print('Error executing SQL: $sql\n  Bindings: $bindings\n  Error message: $e');
      rethrow;
    }
  }

  T _mapRow<T>(Map<String, dynamic> row, EntitySupport entitySupport, Type type, List<Field> selectFields,
      Iterable<_Table> joinTables) {
    if (joinTables.isEmpty) {
      var converted = _convertResult<T>(row, type);
      if (selectFields.isEmpty) {
        return entitySupport.deserialize(converted);
      } else {
        return _mapFields(converted, selectFields) as T;
      }
    } else {
      return {
        entitySupport.name: _mapRow(row, entitySupport, type, selectFields, []),
        ...{
          for (var table in joinTables)
            registry.lookup(table.type).name: _mapRow(row, registry.lookup(table.type), table.type, selectFields, [])
        }
      } as T;
    }
  }

  Map<String, dynamic> _mapFields(Map<String, dynamic> converted, List<Field> selectFields) {
    return {for (var field in selectFields) field.alias: field.resolve(converted)};
  }

  dynamic _convertResult<T>(dynamic value, [Type type]) {
    if (value is Map) {
      return value.map((key, value) => MapEntry(_camelCase(key), _deserialize<T>(_camelCase(key), value, type)));
    } else {
      return value;
    }
  }

  dynamic _deserialize<T>(String name, dynamic value, [Type type]) {
    if (objectRepresentation == ObjectRepresentation.json && value is String) {
      var entitySupport = registry.lookup<T>(type);
      if (entitySupport != null && entitySupport.fieldTypes[name] != String) {
        return _fromJson(jsonDecode(value), entitySupport.fieldTypes[name]);
      }
    }
    return _convertResult<T>(value, type);
  }

  @override
  SelectStep select(List<Field> fields) => _SelectStep(this, fields);

  @override
  QueryStep<T> selectFrom<T>([Type type, String alias]) => _QueryStep<T>(this, type, [], {});

  @override
  Future store(dynamic entity) async {
    var connection = await _openConnection;
    var entitySupport = registry.lookup(entity.runtimeType);
    var tableName = _snakeCase(entitySupport.name);
    var fieldNames = entitySupport.fields.map((field) => _snakeCase(field));
    var fieldValues = _addEntityValues('', {}, entity);
    var statement = 'INSERT INTO "$tableName"(${fieldNames.map((field) => '"$field"').join(', ')}) '
        'VALUES(${entitySupport.fields.map((field) => _fieldExpression(field, entitySupport.getFieldValue(field, entity))).join(', ')})';

    return connection.execute(statement, substitutionValues: fieldValues);
  }

  String _fieldExpression(String field, dynamic value) {
    var fieldExpressionMatcher = matcher<dynamic, String>()
        .whenNull((v) => 'NULL')
        .when(any([typeIs<String>(), typeIs<num>(), typeIs<DateTime>(), typeIs<bool>()]), (v) => '@$field')
        .whenIs<Iterable>((v) => _arrayExpression(v, field))
        .otherwise((v) => _entityExpression(v, field));
    return fieldExpressionMatcher.apply(value);
  }

  String _arrayExpression(Iterable iterable, String field) {
    var index = 0;
    if (objectRepresentation == ObjectRepresentation.typesAndArrays) {
      return 'ARRAY[${iterable.map((e) => _fieldExpression(field + '_${index++}', e)).join(', ')}]';
    } else {
      return '@$field';
    }
  }

  String _entityExpression(dynamic value, String field) {
    var entitySupport = registry.lookup(value.runtimeType);
    var fieldExpressions =
        entitySupport.fields.map((f) => _fieldExpression('${field}_$f', entitySupport.getFieldValue(f, value)));
    if (objectRepresentation == ObjectRepresentation.typesAndArrays) {
      return 'ROW(${fieldExpressions.join(', ')})';
    } else {
      return '@$field';
    }
  }

  Map<String, dynamic> _addEntityValues(String prefix, Map<String, dynamic> values, dynamic entity) {
    var entitySupport = registry.lookup(entity.runtimeType);
    for (var field in entitySupport.fields) {
      var value = entitySupport.getFieldValue(field, entity);
      _addFieldValue(prefix + field, values, value);
    }
    return values;
  }

  void _addFieldValue(String prefix, Map<String, dynamic> values, dynamic value) {
    matcher<dynamic, void>()
        .whenNull((v) => values[prefix] = null)
        .when(any([typeIs<String>(), typeIs<num>(), typeIs<DateTime>(), typeIs<bool>()]), (v) => values[prefix] = v)
        .whenIs<Iterable>((v) => _addArrayValues(prefix, values, v))
        .otherwise((v) => objectRepresentation == ObjectRepresentation.typesAndArrays
            ? _addEntityValues(prefix + '_', values, v)
            : values[prefix] = jsonEncode(_toJson(v)))
        .apply(value);
  }

  void _addArrayValues(String prefix, Map<String, dynamic> values, Iterable iterable) {
    var index = 0;
    if (objectRepresentation == ObjectRepresentation.typesAndArrays) {
      for (var value in iterable) {
        _addFieldValue('${prefix}_${index++}', values, value);
      }
    } else {
      _addFieldValue(prefix, values, jsonEncode(_toJson(iterable)));
    }
  }

  Future<PostgreSQLConnection> get _openConnection async {
    if (_connection.isClosed) {
      await _connection.open();
    }
    return _connection;
  }

  dynamic _toJson(dynamic object) {
    return matcher<dynamic, dynamic>()
        .whenNull((v) => null)
        .whenIs<Map>((o) => o.map((key, value) => MapEntry(key, _toJson(value))))
        .whenIs<Iterable>((o) => o.map((value) => _toJson(value)).toList())
        .whenIs<DateTime>((o) => o.toIso8601String())
        .when(any([typeIs<String>(), typeIs<num>(), typeIs<bool>()]), (v) => v)
        .otherwise((input) {
      var entitySupport = registry.lookup(object.runtimeType);
      return entitySupport != null ? entitySupport.serialize(input) : input.toJson();
    }).apply(object);
  }

  dynamic _fromJson(dynamic json, Type type) {
    return matcher<dynamic, dynamic>()
        .when(any([typeIs<String>(), typeIs<num>(), typeIs<bool>()]), (v) => v)
        .whenIs<Iterable>((iterable) => iterable.map((e) => _fromJson(e, dynamic)).toList())
        .whenIs<Map>((map) => map.map((key, value) => MapEntry(key, _fromJson(value, dynamic))))
        .apply(json);
  }

  @override
  DeleteStep<T> deleteFrom<T>([Type type]) {
    // TODO: implement deleteFrom
    throw UnimplementedError();
  }
}

class _SelectStep implements SelectStep {
  final Box _box;
  final List<Field> _fields;

  _SelectStep(this._box, this._fields);

  @override
  _QueryStep from(Type type, [String alias]) => _QueryStep(_box, type, _fields, {});
}

class _QueryStep<T> extends _ExpectationStep<T> implements QueryStep<T> {
  final Map<String, int> _latestIndex;

  _QueryStep(PostgresBox box, Type type, List<Field> fields, this._latestIndex) : super(box, type ?? T, fields);

  _QueryStep.withCondition(_QueryStep<T> query, String condition, Map<String, dynamic> bindings, this._latestIndex)
      : super.fromExisting(query, conditions: condition, bindings: bindings);

  _QueryStep.withJoin(_QueryStep<T> query, Type type, String join, Map<String, dynamic> bindings, this._latestIndex)
      : super.fromExisting(query,
            bindings: bindings,
            joins: {...query._joins, _Table(type, _snakeCase(query.box.registry.lookup(type).name)): join});

  @override
  OrderByStep<T> orderBy(String field) => _OrderByStep(field, this);

  @override
  WhereStep<T, QueryStep<T>> where(String field) => _QueryWhereStep(field, this);

  @override
  WhereStep<T, QueryStep<T>> and(String field) => _AndStep(field, this);

  @override
  WhereStep<T, QueryStep<T>> or(String field) => _OrStep(field, this);

  String _index(String field) {
    var latest = _latestIndex[field] ?? 0;
    var result = '$field${++latest}';
    _latestIndex[field] = latest;
    return result.replaceAll('.', '_');
  }

  Map<String, dynamic> _indexIterable(String field, Iterable<dynamic> values) =>
      {for (var v in values) _index(field): v};

  @override
  JoinStep<T> innerJoin(Type type, [String alias]) => _JoinStep(type, this);
}

class _JoinStep<T> implements JoinStep<T> {
  final Type type;
  final _QueryStep<T> query;

  _JoinStep(this.type, this.query);

  @override
  WhereStep<T, QueryStep<T>> on(String field) => _JoinOnStep(field, type, query);
}

class _JoinOnStep<T> extends _QueryWhereStep<T> {
  final Type type;

  _JoinOnStep(String field, this.type, _QueryStep<T> query) : super(field, query);

  @override
  QueryStep<T> _queryStep(String condition, Map<String, dynamic> bindings) => _QueryStep<T>.withJoin(
      query, type, combine(condition), Map.from(bindings)..addAll(query._bindings), query._latestIndex);

  @override
  QueryStep<T> equals(dynamic value) {
    return _queryStep('${_fieldName(field, joinType: type)} = ${_fieldName(value, joinType: type)}', {});
  }
}

class _QueryWhereStep<T> implements WhereStep<T, QueryStep<T>> {
  final String field;
  final _QueryStep<T> query;

  _QueryWhereStep(this.field, this.query);

  String combine(String condition) => condition;

  QueryStep<T> _queryStep(String condition, Map<String, dynamic> bindings) => _QueryStep<T>.withCondition(
      query, combine(condition), Map.from(bindings)..addAll(query._bindings), query._latestIndex);

  @override
  WhereStep<T, QueryStep<T>> not() => _NotStep(this);

  @override
  QueryStep<T> equals(dynamic value) {
    var index = query._index(field);
    return _queryStep('${_fieldName(field)} = @$index', {index: value});
  }

  @override
  QueryStep<T> like(String expression) {
    var index = query._index(field);
    return _queryStep('${_fieldName(field)} LIKE @$index', {index: expression});
  }

  @override
  QueryStep<T> gt(dynamic value) {
    var index = query._index(field);
    return _queryStep('${_fieldName(field)} > @$index', {index: value});
  }

  @override
  QueryStep<T> gte(dynamic value) {
    var index = query._index(field);
    return _queryStep('${_fieldName(field)} >= @$index', {index: value});
  }

  @override
  QueryStep<T> lt(dynamic value) {
    var index = query._index(field);
    return _queryStep('${_fieldName(field)} < @$index', {index: value});
  }

  @override
  QueryStep<T> lte(dynamic value) {
    var index = query._index(field);
    return _queryStep('${_fieldName(field)} <= @$index', {index: value});
  }

  @override
  QueryStep<T> between(dynamic value1, dynamic value2) {
    var index1 = query._index(field);
    var index2 = query._index(field);
    return _queryStep('${_fieldName(field)} BETWEEN @$index1 AND @$index2', {index1: value1, index2: value2});
  }

  @override
  QueryStep<T> in_(Iterable<dynamic> values) {
    var indexed = query._indexIterable(field, values);
    return _queryStep('${_fieldName(field)} IN (${indexed.keys.map((f) => '@$f').join(', ')})', indexed);
  }

  @override
  QueryStep<T> contains(dynamic value) {
    var index = query._index(field);
    if (query.box.objectRepresentation == ObjectRepresentation.json) {
      return _queryStep('${_fieldName(field, asJson: true)} ? @$index', {index: value});
    } else {
      return _queryStep('${_fieldName(field)} @> ARRAY[@$index]', {index: value});
    }
  }

  String _fieldName(String field, {bool asJson = false, Type joinType}) {
    if (field.contains('.')) {
      var parts = field.split('.');
      if (query.box.objectRepresentation == ObjectRepresentation.json && !_isTable(parts[0], joinType)) {
        var partsInBetween = parts.sublist(1, parts.length - 1);
        return '(${_snakeCase(parts.first)}'
            '${partsInBetween.isNotEmpty ? '->' + partsInBetween.map((part) => "'$part'").join('->') : ''}'
            "${asJson ? '->' : '->>'}'${parts.last}'${asJson ? ')::jsonb' : ')'}";
      } else {
        return '"${parts.map(_snakeCase).join('"."')}"';
      }
    } else {
      return _snakeCase(field);
    }
  }

  bool _isTable(String name, Type joinType) =>
      query.box.registry.lookup(query._type).name == name ||
      (joinType != null && query.box.registry.lookup(joinType).name == name) ||
      query._joins.keys.any((joinTable) =>
          joinTable.alias != null ? joinTable.alias == name : query.box.registry.lookup(joinTable.type).name == name);
}

class _AndStep<T> extends _QueryWhereStep<T> {
  _AndStep(String field, _QueryStep<T> query) : super(field, query);

  @override
  String combine(String conditions) =>
      query._conditions != null ? '(${query._conditions} AND $conditions)' : conditions;
}

class _OrStep<T> extends _QueryWhereStep<T> {
  _OrStep(String field, _QueryStep<T> query) : super(field, query);

  @override
  String combine(String conditions) => query._conditions != null ? '(${query._conditions} OR $conditions)' : conditions;
}

class _NotStep<T> extends _QueryWhereStep<T> {
  _NotStep(_QueryWhereStep<T> whereStep) : super(whereStep.field, whereStep.query);

  @override
  String combine(String conditions) => 'NOT $conditions';
}

class _OrderByStep<T> implements OrderByStep<T> {
  final String field;
  final _QueryStep<T> _query;

  _OrderByStep(this.field, this._query);

  @override
  ExpectationStep<T> ascending() => _ExpectationStep.fromExisting(_query, order: {..._query._order, field: 'ASC'});

  @override
  ExpectationStep<T> descending() => _ExpectationStep.fromExisting(_query, order: {..._query._order, field: 'DESC'});
}

class _ExpectationStep<T> extends ExpectationStep<T> {
  @override
  final PostgresBox box;
  final String _conditions;
  final Map<_Table, String> _joins;
  final Map<String, dynamic> _bindings;
  final Map<String, String> _order;
  final Type _type;
  final List<Field> _selectFields;

  _ExpectationStep(this.box, this._type, this._selectFields)
      : _conditions = '',
        _joins = {},
        _bindings = {},
        _order = {};

  _ExpectationStep.fromExisting(
    _ExpectationStep step, {
    String conditions,
    Map<String, dynamic> bindings,
    Map<String, String> order,
    Map<_Table, String> joins,
    List<Field> selectFields,
  })  : box = step.box,
        _conditions = conditions ?? step._conditions,
        _joins = joins ?? step._joins,
        _bindings = bindings ?? step._bindings,
        _order = order ?? step._order,
        _type = step._type,
        _selectFields = selectFields ?? step._selectFields;

  @override
  Stream<T> stream({int limit = 1000000, int offset = 0}) =>
      box._query<T>(_conditions, _bindings, _order, _type, limit, offset, _selectFields, _joins);
}

class _Table {
  final Type type;
  final String name;
  final String alias;

  _Table(this.type, this.name, [this.alias]);
}

String _snakeCase(String field) => ReCase(field).snakeCase;

String _camelCase(String field) => ReCase(field).camelCase;
