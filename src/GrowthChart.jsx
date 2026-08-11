import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer } from 'recharts';

// recharts is only needed for this one chart — split into its own file so
// React.lazy() can keep it out of the main bundle until the Dashboard's
// Growth section actually mounts.
export default function GrowthChart({ data, dataKey, name, stroke, formatValue }) {
  return (
    <ResponsiveContainer>
      <LineChart data={data}>
        <CartesianGrid strokeDasharray="3 3" stroke="#E3E6EC" />
        <XAxis dataKey="month" tick={{ fontSize: 12 }} />
        <YAxis tick={{ fontSize: 12 }} tickFormatter={formatValue} width={80} />
        <Tooltip formatter={formatValue} />
        <Legend />
        <Line type="monotone" dataKey={dataKey} name={name} stroke={stroke} strokeWidth={2} dot={{ r: 3 }} />
      </LineChart>
    </ResponsiveContainer>
  );
}
